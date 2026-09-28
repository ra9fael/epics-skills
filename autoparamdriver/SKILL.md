---
name: autoparamdriver
description: Comprehensive architecture design, C++ driver development, grammar-based protocol parsing, lifecycle memory optimization, and production troubleshooting guide for the EPICS autoParamDriver module. Use when developing or refactoring EPICS hardware communication drivers, eliminating asynPortDriver boilerplate, implementing dynamic register/bus addressing, or handling I/O Intr push notifications.
---

# EPICS autoParamDriver Development Guide and Architecture Reference

`autoParamDriver` is a modern C++ base class extending `asynPortDriver`, widely adopted by Cosylab, ESO, and major scientific facilities (accelerators, telescopes, Beckhoff PLC ADS, MQTT gateways). Its core objective is to **eliminate the boilerplate code and manual parameter indexing of native asyn, enabling on-demand parameter creation and grammar-based dynamic binding**.

## 1. Native asynPortDriver Bottlenecks and Modern Solutions

### 1.1 Pain Points of Native asynPortDriver

1. **High Maintenance Overhead for Redundant Mapping**: Developers must define integer indices (`int P_MyParam;`) and explicitly call `createParam("MY_PARAM", ...)` in the constructor to bind strings to indices.

2. **Switch-Case Dispatch Overhead**: Every read or write operation overrides monolithic methods (e.g., `writeInt32`, `readFloat64`), leading to large `switch(pasynUser->reason)` blocks or nested `if-else` chains.

3. **Recompilation for Every Register Change**: Adding or modifying a hardware register requires editing C++ source code, recompiling the binary, and restarting the IOC.

### 1.2 Core Architectural Mechanisms of autoParamDriver

| Dimension              | Native asynPortDriver                                            | autoParamDriver                                                                                               |
| ---------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Parameter Creation** | Explicitly hardcoded calls to `createParam` in constructor       | **On-demand creation**: Parameters are dynamically assigned IDs during `.db` parsing                          |
| **Logic Dispatch**     | Centralized in monolithic `readXxx` / `writeXxx` virtual methods | **Decoupled OOP dispatch**: Parameters/patterns bind directly to dedicated handler functions or lambdas       |
| **Dynamic Addressing** | Each register/address requires a distinct static parameter ID    | **Grammar-based binding**: Pattern matching handles entire bus address ranges with single handlers            |
| **Parsing Overhead**   | Direct integer indexing with no runtime parsing                  | **Compile-once pointer dispatch**: Pre-compiles metadata at init; zero string-parsing overhead during runtime |

---

## 2. Architecture Lifecycle: Startup Compilation vs. Runtime Dispatch

To eliminate string parsing overhead (e.g., `regex` or `sscanf`) during high-frequency execution, `autoParamDriver` compiles metadata during startup and uses direct pointer dereferencing at runtime:

```text
[IOC Initialization: Loading *.db Records]
        │
        ▼ drvUserCreate hook triggered
[autoParamDriver Parameter Interception]
        │ Unregistered name detected -> allocate parameter index dynamically
        ▼
[Parameter Compiler / Hook Execution]
        │ Regex parses parameter string (address, bitmask, scale, data type)
        │ Allocate: new RegisterContext{ ... }
        ▼
[Attach Private Context]
        │ Cache pointer via var->setUserData(ctx) in DeviceVariable node
========================================================================
[IOC Steady-State Runtime (High-frequency 1 kHz polling or I/O Intr)]
        │
        ▼ Read/Write operation invoked (pasynUser->reason)
[Direct Dispatch to Bound Handler]
        │
        ▼
[Retrieve Pre-compiled Context]
        │ RegisterContext *ctx = static_cast<RegisterContext*>(var->getUserData());
        ▼
[Hardware Bus Access]
        │ Direct pointer/bus access with bitwise operations (< 1 µs overhead)

```

---

## 3. Core Design Patterns

### Pattern 1: Fixed Binding with Closures (Zero-Boilerplate)

Eliminates variable declarations and switch-case logic for fixed hardware channels:

```cpp
// Bind write operation
bindWriteHandler<epicsFloat64>("TEMP_SP",
    [this](autoParamDriver::DeviceVariable *var, epicsFloat64 val) {
        return this->hardwareSetTemp(val);
    });

// Bind read operation
bindReadHandler<epicsFloat64>("TEMP_VAL",
    [this](autoParamDriver::DeviceVariable *var, epicsFloat64 &val) {
        val = this->hardwareGetTemp();
        return asynSuccess;
    });

```

### Pattern 2: Grammar-based Dynamic Binding

Treats parameter names as a domain-specific micro-syntax (DSL), such as `REG:<address>[.<bitrange>][:<type_conversion>]`:

- `.db` definition: `field(INP, "@asyn(PORT, 0) REG:0x10A4:SCALE(0.001)")`

- The C++ driver registers a single `REG:.*` pattern rule to handle thousands of bus registers dynamically.

### Pattern 3: Passive Scanning and Subscriptions (I/O Intr Scanning)

Designed for push-based hardware communication (e.g., MQTT, Ethernet broadcasts, PLC event notifications):

1. Implement interrupt subscription hooks in the handler (`bindInterruptHandler`).

2. When a record is configured with `SCAN="I/O Intr"`, the driver hook is triggered with `cancel = false` to subscribe to the hardware/broker.

3. When all records unsubscribe, the driver receives `cancel = true` and tears down the subscription to conserve bus bandwidth.

4. Incoming hardware updates trigger `setDoubleParam()` and push updates to records through `callParamCallbacks()`.

### Pattern 4: Rich Status and Alarm Returns (Rich ResultBase)

Native asyn returns only `asynStatus` (`asynSuccess` / `asynError`). `autoParamDriver` supports returning structured results with alarm severity and status:

```cpp
// Direct alarm attachment in read handlers
ReadResult<epicsFloat64> result(currentVal);
if (currentVal > 100.0) {
    result.setAlarm(epicsSevMajor, epicsAlarmHiHi);
}
return result;

```

---

## 4. Production Implementation Examples

### 4.1 Implementation 1: Dynamic Register Bus Driver (`GenericBusDriver.cpp`)

```cpp
#include <iostream>
#include <string>
#include <regex>
#include <memory>
#include <cstdint>
#include <cantProceed.h>
#include "autoParamDriver.h"

// Pre-compiled parameter context: parsed once at init and retained in memory
struct RegisterContext {
    uint32_t address;
    uint32_t mask;
    uint8_t  shift;
    double   scale;

    RegisterContext() : address(0), mask(0xFFFFFFFF), shift(0), scale(1.0) {}
};

class GenericBusDriver : public autoParamDriver {
public:
    GenericBusDriver(const char *portName)
        : autoParamDriver(portName, 0 /*maxAddr*/, 0 /*paramTableSize*/)
    {
        registerGenericBusHandlers();
    }

    virtual ~GenericBusDriver() {
        // Free dynamically allocated context objects to prevent memory leaks
        for (size_t i = 0; i < this->getParamTableSize(); ++i) {
            autoParamDriver::DeviceVariable *var = this->getDeviceVariable(i);
            if (var && var->getUserData()) {
                delete static_cast<RegisterContext*>(var->getUserData());
                var->setUserData(nullptr);
            }
        }
    }

private:
    void registerGenericBusHandlers() {
        // 1. Generic read handler (matching REG:.* regex pattern)
        bindReadHandler<epicsFloat64>(
            "REG:.*",
            [this](autoParamDriver::DeviceVariable *var, epicsFloat64 &val) {
                RegisterContext *ctx = this->getOrCompileContext(var);
                if (!ctx) return asynError;

                // Low-level hardware bus read
                uint32_t raw = this->busRead(ctx->address);

                // Apply bitmask, bitshift, and engineering unit scaling
                uint32_t masked = (raw & ctx->mask) >> ctx->shift;
                val = static_cast<epicsFloat64>(masked) * ctx->scale;

                return asynSuccess;
            }
        );

        // 2. Generic write handler
        bindWriteHandler<epicsFloat64>(
            "REG:.*",
            [this](autoParamDriver::DeviceVariable *var, epicsFloat64 val) {
                RegisterContext *ctx = this->getOrCompileContext(var);
                if (!ctx) return asynError;

                // Scale physical quantity back to raw integer value
                uint32_t rawVal = static_cast<uint32_t>(val / ctx->scale);

                if (ctx->mask != 0xFFFFFFFF) {
                    // Perform Read-Modify-Write for bitfields (requires mutex locking)
                    uint32_t current = this->busRead(ctx->address);
                    current &= ~(ctx->mask);
                    current |= (rawVal << ctx->shift) & ctx->mask;
                    this->busWrite(ctx->address, current);
                } else {
                    this->busWrite(ctx->address, rawVal);
                }

                return asynSuccess;
            }
        );
    }

    // Compile and cache the string syntax once during initialization
    RegisterContext* getOrCompileContext(autoParamDriver::DeviceVariable *var) {
        RegisterContext *ctx = static_cast<RegisterContext*>(var->getUserData());
        if (ctx) return ctx;

        ctx = new RegisterContext();
        const std::string name = var->getName();

        // Syntax: REG:0x<HEX>[:BITS(<high>,<low>)][:SCALE(<double>)]
        static const std::regex syntaxRegex(
            R"(REG:(0x[0-9A-Fa-f]+)(?::BITS\((\d+),(\d+)\))?(?::SCALE\(([-+]?[0-9]*\.?[0-9]+)\))?)"
        );
        std::smatch match;

        if (std::regex_match(name, match, syntaxRegex)) {
            // Extract base register address
            ctx->address = std::stoul(match[1].str(), nullptr, 16);

            // Extract bitfield definitions
            if (match[2].matched && match[3].matched) {
                uint8_t high = static_cast<uint8_t>(std::stoul(match[2].str()));
                uint8_t low  = static_cast<uint8_t>(std::stoul(match[3].str()));
                ctx->shift = low;
                ctx->mask  = ((1ULL << (high - low + 1)) - 1) << low;
            }

            // Extract engineering unit scaling factor
            if (match[4].matched) {
                ctx->scale = std::stod(match[4].str());
            }

            var->setUserData(ctx);
            return ctx;
        } else {
            asynPrint(this->pasynUserSelf, ASYN_TRACE_ERROR,
                      "GenericBusDriver: Failed to parse parameter syntax -> %s\n", name.c_str());
            delete ctx;
            return nullptr;
        }
    }

    // Hardware interface mock methods
    uint32_t busRead(uint32_t addr) { return 0x00FF; }
    void busWrite(uint32_t addr, uint32_t val) {
        std::cout << "[Bus Write] Addr: 0x" << std::hex << addr << " Val: 0x" << val << std::dec << "\n";
    }
};

```

### 4.2 Implementation 2: Asynchronous Push & I/O Intr Subscription Driver (`IoIntrStreamDriver.cpp`)

```cpp
#include <iostream>
#include <string>
#include <unordered_map>
#include <thread>
#include <atomic>
#include <chrono>
#include <cantProceed.h>
#include <epicsThread.h>
#include "autoParamDriver.h"

// Context stored per parameter to track subscription counts and topic details
struct StreamParamContext {
    std::string topic;
    std::atomic<int> subscriberCount{0};

    explicit StreamParamContext(std::string t) : topic(std::move(t)) {}
};

class IoIntrStreamDriver : public autoParamDriver {
public:
    IoIntrStreamDriver(const char *portName)
        : autoParamDriver(portName, 0 /*maxAddr*/, 0 /*paramTableSize*/),
          m_running(true)
    {
        // 1. Bind handlers for stream data (Read Handler & Interrupt Handler)
        registerStreamHandlers();

        // 2. Start a background worker simulating asynchronous push events
        m_workerThread = std::thread(&IoIntrStreamDriver::hardwareListenerWorker, this);
    }

    virtual ~IoIntrStreamDriver() {
        // Stop background worker
        m_running = false;
        if (m_workerThread.joinable()) {
            m_workerThread.join();
        }

        // Clean up cached parameter contexts
        this->lock();
        for (size_t i = 0; i < this->getParamTableSize(); ++i) {
            autoParamDriver::DeviceVariable *var = this->getDeviceVariable(i);
            if (var && var->getUserData()) {
                delete static_cast<StreamParamContext*>(var->getUserData());
                var->setUserData(nullptr);
            }
        }
        this->unlock();
    }

private:
    std::atomic<bool> m_running;
    std::thread m_workerThread;

    void registerStreamHandlers() {
        // Handle read operations for records scanning periodically or initializing
        bindReadHandler<epicsFloat64>(
            "STREAM:.*",
            [this](autoParamDriver::DeviceVariable *var, epicsFloat64 &val) {
                this->getDoubleParam(var->getIndex(), &val);
                return asynSuccess;
            }
        );

        // Hook interrupt subscriptions for I/O Intr management
        bindInterruptHandler(
            "STREAM:.*",
            [this](autoParamDriver::DeviceVariable *var, bool cancel) {
                StreamParamContext *ctx = static_cast<StreamParamContext*>(var->getUserData());
                if (!ctx) {
                    std::string varName = var->getName();
                    std::string topic = varName.substr(7); // Strip "STREAM:"
                    ctx = new StreamParamContext(topic);
                    var->setUserData(ctx);
                }

                if (!cancel) {
                    // Record attached with SCAN="I/O Intr"
                    int count = ++ctx->subscriberCount;
                    if (count == 1) {
                        this->subscribeHardwareStream(ctx->topic);
                    }
                    asynPrint(this->pasynUserSelf, ASYN_TRACE_FLOW,
                              "IoIntrStreamDriver: Subscribed to '%s' (Total listeners: %d)\n",
                              ctx->topic.c_str(), count);
                } else {
                    // Record detached or SCAN changed
                    int count = --ctx->subscriberCount;
                    if (count <= 0) {
                        ctx->subscriberCount = 0;
                        this->unsubscribeHardwareStream(ctx->topic);
                    }
                    asynPrint(this->pasynUserSelf, ASYN_TRACE_FLOW,
                              "IoIntrStreamDriver: Unsubscribed from '%s' (Remaining listeners: %d)\n",
                              ctx->topic.c_str(), count);
                }
                return asynSuccess;
            }
        );
    }

    void subscribeHardwareStream(const std::string &topic) {
        std::cout << "[Hardware Interface] >>> Subscribed to stream: " << topic << std::endl;
    }

    void unsubscribeHardwareStream(const std::string &topic) {
        std::cout << "[Hardware Interface] <<< Unsubscribed from stream: " << topic << std::endl;
    }

    void hardwareListenerWorker() {
        double counter = 0.0;
        while (m_running) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));

            this->lock();
            for (size_t i = 0; i < this->getParamTableSize(); ++i) {
                autoParamDriver::DeviceVariable *var = this->getDeviceVariable(i);
                if (!var) continue;

                StreamParamContext *ctx = static_cast<StreamParamContext*>(var->getUserData());
                if (ctx && ctx->subscriberCount.load() > 0) {
                    double simulatedValue = 20.0 + (counter++ * 0.1);
                    this->setDoubleParam(var->getIndex(), simulatedValue);
                    this->callParamCallbacks(var->getIndex());
                }
            }
            this->unlock();
        }
    }
};

```

---

## 5. EPICS Database Configurations

### 5.1 Bus Device Database (`busDevice.db`)

```epics
# 1. Direct 32-bit register read (scanned every 0.5s)
record(ai, "$(DEV):RAW:REG1000") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT), 0) REG:0x1000")
    field(SCAN, ".5 second")
    field(PREC, "0")
}

# 2. Bitfield read [15:8] with unit conversion
record(ai, "$(DEV):VOLT:MON") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT), 0) REG:0x1004:BITS(15,8):SCALE(0.01)")
    field(SCAN, ".1 second")
    field(EGU,  "V")
    field(PREC, "2")
}

# 3. DAC analog output write (converts engineering units back to register raw values)
record(ao, "$(DEV):VOLT:SP") {
    field(DTYP, "asynFloat64")
    field(OUT,  "@asyn($(PORT), 0) REG:0x2000:SCALE(0.001)")
    field(EGU,  "V")
    field(PREC, "3")
}

```

### 5.2 Stream & Push Database (`streamDevice.db`)

```epics
# Passively updated when the driver receives asynchronous packets
record(ai, "$(DEV):TEMP:STREAM") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT), 0) STREAM:sensors/ambient_temp")
    field(SCAN, "I/O Intr")
    field(PREC, "2")
    field(EGU,  "degC")
}

# Polled fallback reading from the same cached parameter
record(ai, "$(DEV):TEMP:POLL") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT), 0) STREAM:sensors/ambient_temp")
    field(SCAN, "5 second")
    field(PREC, "2")
}

```

---

## 6. Reference Implementations

1. **`epics-modules/mqtt`**:

- Uses patterns such as `FLAT:FLOAT:/topic/path` and `JSON:/topic/path:$.sensor.temp`.

- Utilizes interrupt subscription hooks to subscribe to topics on the MQTT broker only when matching PVs exist in the IOC.

2. **`Cosylab/adsDriver` (Beckhoff TwinCAT PLC)**:

- Maps directly to internal PLC symbolic names (e.g., `MAIN.Axis1.fPosition`).

- Dynamically resolves PLC handles and updates I/O Intr records upon variable value changes.

---

## 7. Gotchas and Best Practices

1. **Destructor Cleanup**:

- Any heap context allocated and bound via `setUserData()` must be iterated and deleted in the driver destructor to avoid memory leaks.

2. **Bitfield Race Conditions (Read-Modify-Write)**:

- When writing to different bitfields within the same register (e.g., `BITS(3,0)` and `BITS(7,4)`), protect the hardware transaction using driver-level locks (`lock()` / `unlock()`) to prevent data corruption.

3. **Thread Safety with Callbacks**:

- Always wrap `callParamCallbacks(index)` within `this->lock()` and `this->unlock()` when updating parameters from an external thread.

4. **Regex Specificity**:

- Avoid overly broad regex patterns (such as `.*`) to prevent conflicts with other commands. Bound patterns with explicit delimiters and prefixes.
