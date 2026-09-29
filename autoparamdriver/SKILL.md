---
name: autoparamdriver
description: Develop and troubleshoot Cosylab autoParamDriver-based EPICS asyn drivers. Use for Autoparam::Driver subclasses, database-driven dynamic parameters, DeviceAddress/DeviceVariable parsing, typed handler registration, I/O Intr callbacks, and the v2.x lifecycle.
---

# Cosylab autoParamDriver

This skill describes the public API of the upstream `Cosylab/autoparamDriver`
module. The examples target v2.1.0 (tag `v2.1.0`, commit
`2159559b24eb45eeb5f77008d0236a80df933519`). Check the checked-out upstream
headers when working against another release.

Upstream: <https://github.com/Cosylab/autoparamDriver>

## What the module does

`Autoparam::Driver` is an `asynPortDriver` that creates a parameter when EPICS
records are initialized. A record's `@asyn(PORT, ADDR) FUNCTION ARGUMENTS`
reason is split into a function and arguments. The derived driver parses those
parts into a `DeviceAddress`, creates a shared `DeviceVariable`, and registers
typed function handlers.

The important distinction is that autoParamDriver does **not** provide a
regular-expression or lambda binding DSL. There are no upstream APIs named
`bindReadHandler`, `bindWriteHandler`, `getParamTableSize`,
`getDeviceVariable`, `setUserData`, or `ReadResult::setAlarm`. Do not present
those as autoParamDriver interfaces.

The lifecycle is:

```text
record initialization -> drvUserCreate()
  -> parseDeviceAddress(function, arguments)
  -> createDeviceVariable(base DeviceVariable)
  -> create/reuse asyn parameter
record processing -> dispatch by function and asyn type
  -> registered typed read/write handler
I/O Intr transition -> InterruptRegistrar(var, cancel)
asynchronous update -> setParam(var, value) + callParamCallbacks()
                       or doCallbacksArray()
```

Record initialization is where address parsing and parameter identity are
established. Runtime dispatch uses the parsed `DeviceVariable`; it is not a
promise of zero-cost execution, and the library does not compile arbitrary
regular expressions for the user.

## Minimal class architecture

A concrete driver normally supplies three pieces:

1. A `DeviceAddress` subclass holding parsed arguments. It must implement
   equality: equal addresses must represent the same underlying device
   variable.
2. A `DeviceVariable` subclass holding driver-specific per-variable state.
   Construct it from the `baseVar` passed to `createDeviceVariable()`; that
   transfers ownership of the base object.
3. An `Autoparam::Driver` subclass implementing `parseDeviceAddress()` and
   `createDeviceVariable()`, then registering static handlers in its
   constructor.

The base class owns created `DeviceVariable` instances and the address objects
associated with them. Do not manually walk an imagined parameter table or put
per-record ownership in a handler.

```cpp
#include <autoparamDriver.h>
#include <autoparamHandler.h>

class Address : public Autoparam::DeviceAddress {
public:
    explicit Address(int channel) : channel(channel) {}
    bool operator==(Autoparam::DeviceAddress const &other) const override {
        auto const *rhs = dynamic_cast<Address const *>(&other);
        return rhs && rhs->channel == channel;
    }
    int channel;
};

class Variable : public Autoparam::DeviceVariable {
public:
    explicit Variable(Autoparam::DeviceVariable *base)
        : Autoparam::DeviceVariable(base) {}
};

class MyDriver : public Autoparam::Driver {
public:
    explicit MyDriver(const char *portName)
        : Autoparam::Driver(portName, Autoparam::DriverOpts()) {
        registerHandlers<epicsFloat64>("VALUE", readValue, writeValue,
                                       registerValueInterrupt);
    }

protected:
    Autoparam::DeviceAddress *parseDeviceAddress(
        std::string const &function, std::string const &arguments) override;
    Autoparam::DeviceVariable *createDeviceVariable(
        Autoparam::DeviceVariable *baseVar) override {
        return new Variable(baseVar);
    }

private:
    static Autoparam::Result<epicsFloat64>
    readValue(Autoparam::DeviceVariable &var);
    static Autoparam::WriteResult
    writeValue(Autoparam::DeviceVariable &var, epicsFloat64 value);
    static asynStatus registerValueInterrupt(Autoparam::DeviceVariable &var,
                                              bool cancel);
};
```

`registerHandlers<T>()` is keyed by an exact function string and a type. The
function is not a regex pattern. `T` must match the asyn interface selected by
the record's device support.

## Parsing record reasons

The driver chooses the grammar. A useful convention is:

```text
@asyn(MYPORT,0) VALUE 12
@asyn(MYPORT,0) SETPOINT 12
@asyn(MYPORT,0) STATUS 12
```

`parseDeviceAddress(function, arguments)` should reject unknown functions and
malformed arguments, validate numeric bounds, return equal address objects for
the same hardware variable, avoid acquiring long-lived resources, and return
`NULL` on failure after reporting a useful error. Temporary address objects
may be created and destroyed during IOC initialization.

The function normally selects the handler family; the arguments identify the
device variable. A different function may refer to the same address but still
require a different typed handler.

## Handler results and supported types

Scalar handlers have these shapes:

```cpp
Autoparam::Result<epicsFloat64> read(Autoparam::DeviceVariable &var);
Autoparam::WriteResult write(Autoparam::DeviceVariable &var,
                             epicsFloat64 value);
```

`Result<T>::value` carries a scalar read value. `ResultBase` contains
`status` (`asynSuccess` by default), `alarmStatus`, `alarmSeverity`, and
the tri-state `processInterrupts` override. For example:

```cpp
Autoparam::Result<epicsFloat64>
MyDriver::readValue(Autoparam::DeviceVariable &var) {
    Autoparam::Result<epicsFloat64> result;
    result.value = readHardware(static_cast<Variable &>(var));
    if (result.value > 100.0) {
        result.alarmStatus = epicsAlarmHiHi;
        result.alarmSeverity = epicsSevMajor;
    }
    return result;
}
```

| `T` | asyn interface | read/write shape |
| --- | --- | --- |
| `epicsInt32` | `asynParamInt32` | `Result<T>` / value |
| `epicsInt64` | `asynParamInt64` | `Result<T>` / value |
| `epicsFloat64` | `asynParamFloat64` | `Result<T>` / value |
| `epicsUInt32` | `asynParamUInt32Digital` | value plus `mask` |
| `Autoparam::Octet` | `asynParamOctet` | `Octet&` buffer |
| `Autoparam::Array<T>` | matching array interface | buffer |

`epicsUInt32` is for digital I/O, not ordinary unsigned integer values. Its
handlers receive a mask and must honor it. Use `epicsInt32` for normal integer
records, or `epicsInt64` where the range requires it.

Array read handlers fill the supplied `Array<T>&` and return `ArrayResult`; they
do not return the array in the result object. `Octet` is string-like and has
special null-termination behavior. Although it derives from `Array<char>`, use
scalar `setParam()`/`callParamCallbacks()` for asynchronous strings, not
`doCallbacksArray()`.

## I/O Intr and asynchronous updates

The fourth argument to `registerHandlers<T>()` is an
`InterruptRegistrar(DeviceVariable &, bool cancel)`:

- `cancel == false` is called when the first record for a variable starts
  `I/O Intr` scanning.
- `cancel == true` is called when the last such record stops scanning.
- Several records can share one `DeviceVariable`; subscribe/unsubscribe only
  on those transitions.

For a scalar update from a listener thread, lock the driver, set the cached
parameter, then publish callbacks:

```cpp
lock();
setParam(var, newValue, asynSuccess);
callParamCallbacks();
unlock();
```

`setParam()` does not itself process `I/O Intr` records. The callback call is
the publication point for one or more scalar updates. For arrays, use
`doCallbacksArray(var, array, status, alarmStatus, alarmSeverity)`. The driver
must be locked when these methods are called outside a read/write handler;
handler calls already occur under the driver's lock.

`getInterruptVariables()` returns variables referenced by `I/O Intr` and
`asyn:READBACK` records. It is useful for a polling thread and is threadsafe.

## Community design patterns

The following are EPICS/asyn community conventions, not additional
autoParamDriver keywords. Keep the distinction clear when adapting them to a
project.

### Function names describe intent

Use stable, semantic function names and put the hardware identity in the
arguments:

```text
VALUE 3
SETPOINT 3
STATUS 3
COMMAND 3
```

Common meanings are `VALUE` for measured/readback data, `SETPOINT` for a
writable target, `STATUS` for state, and `COMMAND` for an action. These names
are project conventions; the library only requires that the function string
match `registerHandlers<T>()` exactly.

Do not use a command parameter as a persistent state parameter. A `RESET` or
`TRIGGER` write reports command acceptance; a separate `STATUS`, `BUSY`, or
`VALUE` parameter reports the resulting device state.

### Keep identity, access, and ownership separate

Use one consistent model:

```text
DeviceAddress  -> which hardware variable (channel/register/bit)
DeviceVariable -> per-variable state and metadata
Driver         -> connection, protocol lock, worker threads, device-wide state
```

Every field that distinguishes two hardware variables must participate in
`DeviceAddress::operator==()`. Do not put sockets, threads, or long-lived
device resources in `DeviceAddress`: temporary address instances can be
destroyed during IOC initialization.

### Choose a deliberate readback policy

Do not update EPICS with a value merely because a write was sent. Choose one
of these policies per parameter family:

```text
write-through       successful write updates the cached value immediately
read-after-write    successful write is followed by a hardware readback
command/readback    command is separate; state changes arrive from hardware
```

Use `command/readback` for asynchronous actuators and devices that can reject
or delay a command. Use `write-through` only when the device contract makes
acceptance equivalent to state change.

### Share device resources at Driver scope

A typical driver owns one connection, one protocol transaction lock, and one
listener or polling worker for many `DeviceVariable`s:

```text
one Driver
  ├── one device connection
  ├── one protocol/transaction mutex
  ├── zero or one listener or polling worker
  └── many DeviceVariable objects
```

Do not create one connection or thread per record unless the hardware protocol
requires it. Keep the EPICS/asyn driver lock, the protocol mutex, and any
third-party callback mutex conceptually separate; document their lock order if
more than one can be held together.

### Manage I/O Intr subscriptions as a state transition

Treat the registrar as a 0-to-1 / 1-to-0 transition, not as a per-record start
and stop callback:

```text
no I/O Intr records -> first record enabled -> start subscription or polling
active subscription -> last record disabled -> stop subscription or polling
```

The underlying subscription should be keyed by `DeviceVariable`. If several
records refer to the same variable, they must share the subscription and must
not start duplicate workers.

### Use cache-first polling when hardware access is slow

For slow or blocking devices, let a worker perform hardware I/O and let
handlers use the driver cache. A polling worker should normally inspect
`getInterruptVariables()` and poll only variables currently needed by
`I/O Intr` or `asyn:READBACK` records. On each update, set one or more cached
parameters under the driver lock and call `callParamCallbacks()` once for the
batch.

For devices with native event notifications, prefer a listener thread and
`setParam()` over unnecessary polling. In both designs, hardware confirmation
remains the source of truth for readback values.

### Keep alarm mapping consistent

Define one project-wide mapping for communication, range, and command errors.
For example:

| Condition | Result status | Typical alarm |
| --- | --- | --- |
| successful operation | `asynSuccess` | no alarm override |
| communication failure | error status | `READ_ALARM` or `WRITE_ALARM` |
| device disconnected | connection error | `COMM_ALARM` |
| device rejects a command | error status | `WRITE_ALARM` |
| valid value outside operating range | success or project-defined error | `HIHI`/`LOLO` |

Do not silently convert a transport failure into a valid cached value. Keep
hardware communication errors, invalid data, and record-processing errors
distinguishable in logs and alarms.

## Designing a driver that does not run out of control

Use the following invariants as the design contract. They are more important
than any particular class layout:

1. **One identity, one variable.** Equal `DeviceAddress` objects refer to one
   hardware variable; unequal addresses never share its cache or subscription.
2. **One owner per resource.** The `Driver` owns device connections and worker
   threads; `DeviceVariable` does not independently destroy shared resources.
3. **One writer for each mutable state.** Define whether a cache is updated by
   a handler, a listener, a poller, or a deliberately serialized combination.
4. **Hardware confirmation wins.** A successful command is not a readback
   update unless the device contract guarantees that equivalence.
5. **Callbacks publish coherent state.** Update related values under the
   driver lock, then publish callbacks after the complete batch is consistent.
6. **Subscriptions have bounded lifetime.** Start them on the first consumer,
   stop them on the last consumer, and stop all workers before destruction.
7. **Blocking is explicit.** Any handler that can wait on network, serial, or
   device I/O requires `DriverOpts::setBlocking(true)`; this does not remove
   the need for locking.
8. **Failures are visible.** Parsing errors, missing handlers, transport
   errors, rejected commands, and stale data must produce diagnosable logs or
   alarms rather than plausible values.

### A bounded state model

For each variable, model the minimum lifecycle explicitly:

```text
Created -> Unsubscribed -> Subscribed -> Unsubscribed -> Destroyed
                         \-> Faulted -> (retry or Unsubscribed)
```

Only subscription-specific activity starts on that transition. A fault should
not silently create an unbounded retry loop: use a bounded retry interval or a
backoff policy, record the fault, and define how recovery returns to the
normal state.

At Driver scope, use this shutdown order:

```text
reject new work
  -> stop subscriptions
  -> signal workers to exit
  -> join workers without holding their required lock
  -> close device resources
  -> call base shutdown implementation
```

Implement cleanup that needs virtual dispatch or intact derived state in
`shutdownPortDriver()`, then call `Autoparam::Driver::shutdownPortDriver()` at
the end. Avoid doing this work only in a destructor after derived state has
already begun disappearing.

### Separate command, state, and diagnostics

For a device action, prefer a bounded flow:

```text
COMMAND write
  -> validate locally
  -> send once or through an explicit queue
  -> record acceptance/failure
  -> wait for confirmation or timeout
  -> publish STATUS/VALUE and alarms
```

Never retry a non-idempotent command automatically unless the protocol
provides a transaction ID or equivalent duplicate protection. Put queue size,
command timeout, retry count, and stale-data timeout in the driver design;
unbounded queues and immediate retry loops are common causes of runaway IOCs.

### Database design guardrails

Keep record templates responsible for EPICS semantics and keep protocol
grammar in one parser. A template should make the function/type relationship
obvious:

```db
record(ai, "$(P)VALUE$(N)") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT),$(ADDR)) VALUE $(CHANNEL)")
    field(SCAN, "I/O Intr")
}
```

Validate substitutions, channel bounds, and function names during IOC
initialization. Prefer one canonical template per parameter family instead of
copying protocol strings across many database files.

### Review checklist for a new driver

- Can every PV reason be mapped unambiguously to one address and one type?
- Does `operator==()` include every hardware identity field?
- Is each connection, thread, queue, and subscription owned exactly once?
- Is the readback policy explicit for every writable parameter?
- Are queue capacity, timeouts, retries, and stale-data behavior bounded?
- Can a communication fault recover without duplicating commands or workers?
- Are asynchronous updates locked and published as coherent batches?
- Does shutdown stop activity before resources and derived state disappear?
- Can an operator distinguish command acceptance, device state, and fault?

## Driver options and lifecycle

`Autoparam::DriverOpts` controls behavior passed to the base constructor:

```cpp
Autoparam::DriverOpts opts;
opts.setBlocking(true)       // required if handlers can block
    .setAutoConnect(false)   // choose explicitly when overriding connect()
    .setAutoDestruct(true)   // delete driver during IOC exit
    .setAutoInterrupts(true);
```

Defaults are non-blocking handlers, autoconnect enabled, no automatic
destruction, and automatic interrupt processing enabled. If network or serial
I/O can block, enable `setBlocking(true)` so asyn uses asynchronous record
processing. This does not make shared driver state thread-safe.

Use `setInitHook()` when communication must start after all records and
`DeviceVariable`s exist. If a derived driver owns worker threads, override
`shutdownPortDriver()`, stop/join them while the object is intact, and call
`Autoparam::Driver::shutdownPortDriver()` at the end. This is the intended
place for cleanup that needs virtual methods or the driver lock.

## Implementation checklist

- Include `autoparamDriver.h` and `autoparamHandler.h`; use namespace
  `Autoparam` (capital A).
- Derive from `Autoparam::Driver`, not a lowercase `autoParamDriver` class.
- Implement `parseDeviceAddress()` and `createDeviceVariable()`.
- Make `DeviceAddress::operator==` compare the complete hardware identity.
- Register exact functions with `registerHandlers<T>()`.
- Match handler types to database `DTYP` and the record interface.
- Treat `DeviceVariable` as shared by records with equal addresses.
- Honor digital masks and array/string buffer sizes.
- Set result status/alarm fields consistently on failures.
- Lock asynchronous `setParam()`/callback publication.
- Make readback policy, retry limits, timeouts, queue capacity, and stale-data
  behavior explicit.
- Keep command acceptance, device state, and diagnostics as separate signals.
- Stop background activity in `shutdownPortDriver()` before destruction.
- Check the release headers and upstream tests before using APIs not listed
  here; do not infer an API from a conceptual example.

## Troubleshooting

**No handler for function/type:** the function or `T` does not match the
registration, or `DTYP` selects another asyn interface.

**Two records unexpectedly share a value:** their parsed `DeviceAddress`
objects compare equal. Include every identity field in `operator==`.

**I/O Intr never starts:** the registrar was null, the record uses another
interface, or the registrar returned an error. It is called only on 0-to-1 and
1-to-0 transitions.

**Callbacks race or deadlock:** protect updates with the driver lock, publish
callbacks after related `setParam()` calls, and do not join a worker while
holding a lock the worker needs.

**Slow device access blocks records:** enable `DriverOpts::setBlocking(true)`
and configure the IOC database/device support for asynchronous asyn processing.

**Readback is surprising:** autoParamDriver can process records marked
`asyn:READBACK`; inspect `getInterruptVariables()` and
`ResultBase::processInterrupts` before adding a second update path.
