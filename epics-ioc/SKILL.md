---
name: epics-ioc
description: Create a complete EPICS IOC from scratch with a custom asynPortDriver -- covering analog, binary, multi-bit, string, waveform, and array PV types
---

# EPICS IOC Skill

You are an expert at creating complete EPICS IOC applications with custom asynPortDriver subclasses. You understand how to connect all five layers of an asyn-based IOC: build system scaffolding, driver code, DBD declarations, database records, and startup scripts. You can produce a working IOC that demonstrates analog, binary, multi-bit, string, waveform, and array PV types using simulated hardware.

---

## 1. IOC Development Overview

### 1.1 The Five Layers of an asyn-Based IOC

Every asyn-based IOC consists of five artifacts that must be created and connected:

| Layer | Artifact | Primary Skill | This Skill Provides |
|-------|----------|---------------|---------------------|
| Build system | `configure/RELEASE`, `src/Makefile`, `Db/Makefile` | `epics-module` | Specific `makeBaseApp.pl` invocation and combined library+IOC Makefile |
| Driver code | asynPortDriver subclass (.h/.cpp) | `asyn-port-driver` | Complete multi-type driver exercising all major parameter types |
| DBD | Registrar fragment + composite DBD | `epics-module` | Driver-specific DBD fragment and assembly rules |
| Database | .db template with DTYP and INST_IO links | `asyn-database` | Template exercising all common asyn DTYP choices |
| Startup | st.cmd with port configuration and record loading | `asyn-port-config` | Complete st.cmd for a local asynPortDriver IOC |

This skill connects all five layers into a single working example. See the referenced skills for exhaustive API references and edge cases.

### 1.2 What This Example Builds

A simulated hardware driver (`simDriver`) and its test IOC (`simIoc`). The driver simulates a multi-function instrument with:

- **Analog output (ao/ai):** Voltage setpoint with noisy readback
- **Analog input (ai):** Temperature with sinusoidal drift
- **Binary output (bo/bi):** Enable/disable switch
- **Multi-bit binary (mbbo/mbbi):** Operating mode with 4 enum states
- **String (stringout/stringin):** Status message
- **Waveform (waveform):** Sine wave with configurable length
- **Long output (longout/longin):** Number of waveform samples

---

## 2. Creating the IOC Skeleton

### 2.1 Running makeBaseApp.pl

From the intended top-level directory, create the IOC using the two-step pattern:

```bash
# Step 1: Create application directories
makeBaseApp.pl -t ioc simIoc

# Step 2: Create iocBoot directories
makeBaseApp.pl -i -t ioc simIoc
```

This creates `configure/`, `simIocApp/` (with `src/` and `Db/`), `iocBoot/iocSimIoc/`, and the top-level `Makefile`.

**Do not use `-t support` for this pattern.** The combined library+IOC approach builds the driver library and the IOC executable from a single `src/Makefile`, avoiding the complexity of a separate support module.

### 2.2 Directory Structure After Creation

```
simIoc/                          # Top-level directory
  Makefile                       # Top-level Makefile (boilerplate, do not edit)
  configure/
    RELEASE                      # EDIT: add ASYN path
    CONFIG                       # Boilerplate
    CONFIG_SITE                  # Boilerplate (override build flags here)
    RULES / RULES_TOP / ...      # Boilerplate
    Makefile                     # Boilerplate
  simIocApp/
    src/
      Makefile                   # EDIT: combined library + IOC
      simDriver.h                # CREATE: driver header
      simDriver.cpp              # CREATE: driver implementation
      simDriver.dbd              # CREATE: DBD registrar fragment
      simIocMain.cpp             # Boilerplate (from makeBaseApp.pl)
    Db/
      Makefile                   # EDIT: add DB += simIoc.db
      simIoc.db                  # CREATE: database template
  iocBoot/
    iocSimIoc/
      st.cmd                     # EDIT: port config, record loading
```

---

## 3. configure/RELEASE

### 3.1 Setting Module Paths

Edit `configure/RELEASE` to add the ASYN module path. EPICS_BASE must remain last:

```makefile
# configure/RELEASE
ASYN = /path/to/asyn
EPICS_BASE = /path/to/epics/base

-include $(TOP)/../RELEASE.local
-include $(TOP)/../RELEASE.$(EPICS_HOST_ARCH).local
-include $(TOP)/configure/RELEASE.local
```

Adjust `/path/to/asyn` and `/path/to/epics/base` for your site. See the `epics-module` skill for full RELEASE rules and the `-include` local override pattern.

### 3.2 configure/CONFIG_SITE

For most use cases, no changes are needed. For debug builds, set `HOST_OPT = NO` and `CROSS_OPT = NO`. See the `epics-module` skill section 4.4 for details.

---

## 4. src/Makefile -- Combined Library + IOC

### 4.1 Complete Makefile

Replace the generated `src/Makefile` with the combined library+IOC pattern. The driver is built as a library (`LIBRARY_IOC`) and linked into the IOC executable (`PROD_IOC`):

```makefile
TOP=../..
include $(TOP)/configure/CONFIG

# Use typed rset/dset (recommended for EPICS 7)
USR_CPPFLAGS += -DUSE_TYPED_RSET -DUSE_TYPED_DSET

#==================================================
# Support library: simDriver
#==================================================
LIBRARY_IOC += simDriver

# Install DBD fragment so downstream IOCs can include it
DBD += simDriver.dbd

# Driver sources
simDriver_SRCS += simDriver.cpp

# Link asyn and EPICS base
simDriver_LIBS += asyn
simDriver_LIBS += $(EPICS_BASE_IOC_LIBS)

#==================================================
# IOC application: simIoc
#==================================================
PROD_IOC = simIoc

# Composite DBD assembled from fragments
DBD += simIoc.dbd
simIoc_DBD += base.dbd
simIoc_DBD += asyn.dbd
simIoc_DBD += simDriver.dbd

# Auto-generated registration
simIoc_SRCS += simIoc_registerRecordDeviceDriver.cpp

# Main entry point (workstation OSs only)
simIoc_SRCS_DEFAULT += simIocMain.cpp
simIoc_SRCS_vxWorks += -nil-

# Link libraries: most dependent first
simIoc_LIBS += simDriver
simIoc_LIBS += asyn
simIoc_LIBS += $(EPICS_BASE_IOC_LIBS)

include $(TOP)/configure/RULES
```

### 4.2 Library Link Ordering

Libraries must be listed in reverse dependency order: most dependent first, `$(EPICS_BASE_IOC_LIBS)` last. The IOC depends on `simDriver`, which depends on `asyn`, which depends on base. See the `epics-module` skill section 6.5 for full linking rules.

### 4.3 Db/Makefile

Add the database file to the installation list:

```makefile
TOP=../..
include $(TOP)/configure/CONFIG

DB += simIoc.db

include $(TOP)/configure/RULES
```

---

## 5. DBD Files

### 5.1 Driver DBD Fragment

Create `src/simDriver.dbd`. This is a single-line fragment declaring the registrar function that registers the iocsh configure command:

```
registrar(simDriverRegister)
```

### 5.2 How the Composite DBD Works

The build system concatenates the `simIoc_DBD` list into `simIoc.dbd`:

```
base.dbd          → standard record types, iocsh commands
asyn.dbd          → asyn driver support
simDriver.dbd     → simDriverRegister()
```

From this composite DBD, the build system auto-generates `simIoc_registerRecordDeviceDriver.cpp`. **Never hand-edit this file.** See the `epics-module` skill section 7.3 for the DBD assembly rules.

---

## 6. The Simulated Hardware Driver

The driver simulates a multi-function instrument. It generates data in a background polling thread and handles writes from EPICS records. Seven parameters cover all major asyn types.

### 6.1 Parameter Type and PV Mapping

| drvInfo String | asynParamType | Write Override | Read Override | Record Pair |
|---|---|---|---|---|
| `VOLTAGE` | `asynParamFloat64` | `writeFloat64` | `readFloat64` | ao / ai_RBV |
| `TEMPERATURE` | `asynParamFloat64` | — (read-only) | `readFloat64` | ai (I/O Intr) |
| `ENABLE` | `asynParamInt32` | `writeInt32` | `readInt32` | bo / bi_RBV |
| `MODE` | `asynParamInt32` | `writeInt32` | `readInt32`, `readEnum` | mbbo / mbbi_RBV |
| `MESSAGE` | `asynParamOctet` | `writeOctet` | `readOctet` | stringout / stringin_RBV |
| `WAVEFORM` | `asynParamFloat64Array` | — (read-only) | `readFloat64Array` | waveform (I/O Intr) |
| `NUM_SAMPLES` | `asynParamInt32` | `writeInt32` | `readInt32` | longout / longin_RBV |

### 6.2 Driver Header (simDriver.h)

```cpp
/* simDriver.h — Simulated multi-function instrument driver */
#ifndef SIM_DRIVER_H
#define SIM_DRIVER_H

#include <asynPortDriver.h>
#include <epicsEvent.h>
#include <epicsTypes.h>

/* drvInfo string constants — must match createParam() and INP/OUT links */
#define P_VoltageString     "VOLTAGE"
#define P_TemperatureString "TEMPERATURE"
#define P_EnableString      "ENABLE"
#define P_ModeString        "MODE"
#define P_MessageString     "MESSAGE"
#define P_WaveformString    "WAVEFORM"
#define P_NumSamplesString  "NUM_SAMPLES"

class simDriver : public asynPortDriver {
public:
    simDriver(const char *portName);

    /* Override write methods for writable parameters */
    virtual asynStatus writeInt32(asynUser *pasynUser, epicsInt32 value);
    virtual asynStatus writeFloat64(asynUser *pasynUser, epicsFloat64 value);
    virtual asynStatus writeOctet(asynUser *pasynUser, const char *value,
                                  size_t nChars, size_t *nActual);

    /* Override read methods for computed/derived values */
    virtual asynStatus readFloat64(asynUser *pasynUser, epicsFloat64 *value);
    virtual asynStatus readFloat64Array(asynUser *pasynUser,
                                        epicsFloat64 *value,
                                        size_t nElements, size_t *nIn);
    virtual asynStatus readEnum(asynUser *pasynUser, char *strings[],
                                int values[], int severities[],
                                size_t nElements, size_t *nIn);

private:
    void simTask();          /* Background simulation thread */
    static void simTaskC(void *p);

    /* Parameter indices (set by createParam) */
    int P_Voltage;
    int P_Temperature;
    int P_Enable;
    int P_Mode;
    int P_Message;
    int P_Waveform;
    int P_NumSamples;

    /* Simulation state */
    epicsEventId wakeEvent_;
    bool running_;
    epicsFloat64 *waveformBuf_;
    size_t waveformSize_;
    double simTime_;
    int modeCycle_;
};

#endif /* SIM_DRIVER_H */
```

### 6.3 Constructor Implementation

```cpp
#include "simDriver.h"

#include <cmath>
#include <cstring>
#include <cstdio>

#include <epicsThread.h>
#include <epicsExport.h>
#include <iocsh.h>

/* ── Background thread trampoline ───────────────────────── */

void simDriver::simTaskC(void *p)
{
    ((simDriver *)p)->simTask();
}

/* ── Constructor ────────────────────────────────────────── */

simDriver::simDriver(const char *portName)
    : asynPortDriver(portName, 1,
        /* interfaceMask: all interfaces this driver supports */
        asynInt32Mask | asynFloat64Mask | asynOctetMask |
        asynFloat64ArrayMask | asynEnumMask | asynDrvUserMask,
        /* interruptMask: all interfaces that trigger I/O Intr */
        asynInt32Mask | asynFloat64Mask | asynOctetMask |
        asynFloat64ArrayMask | asynEnumMask,
        0,    /* asynFlags — no ASYN_CANBLOCK (no real I/O) */
        1,    /* autoConnect — always connect */
        0, 0) /* default priority, stack size */
    , wakeEvent_(epicsEventCreate(epicsEventEmpty))
    , running_(true)
    , waveformBuf_(NULL)
    , waveformSize_(1024)
    , simTime_(0.0)
    , modeCycle_(0)
{
    /* ── Create parameters for each instrument signal ───── */
    createParam(P_VoltageString,     asynParamFloat64,      &P_Voltage);
    createParam(P_TemperatureString, asynParamFloat64,      &P_Temperature);
    createParam(P_EnableString,      asynParamInt32,        &P_Enable);
    createParam(P_ModeString,        asynParamInt32,        &P_Mode);
    createParam(P_MessageString,     asynParamOctet,        &P_Message);
    createParam(P_WaveformString,    asynParamFloat64Array, &P_Waveform);
    createParam(P_NumSamplesString,  asynParamInt32,        &P_NumSamples);

    /* ── Set initial values ─────────────────────────────── */
    setDoubleParam(P_Voltage,     0.0);
    setDoubleParam(P_Temperature, 25.0);
    setIntegerParam(P_Enable,     0);
    setIntegerParam(P_Mode,       0);
    setStringParam(P_Mode,        "Single");      /* initial enum string */
    setStringParam(P_Message,     "System ready");
    setIntegerParam(P_NumSamples, (int)waveformSize_);

    /* ── Allocate waveform buffer ───────────────────────── */
    waveformBuf_ = (epicsFloat64 *)calloc(waveformSize_, sizeof(epicsFloat64));

    /* ── Launch background simulation thread ────────────── */
    epicsThreadCreate("simTask",
        epicsThreadPriorityMedium,
        epicsThreadGetStackSize(epicsThreadStackMedium),
        simTaskC, this);
}
```

### 6.4 Background Simulation Task

The polling thread runs at ~1 Hz, generating simulated data and triggering callbacks:

```cpp
void simDriver::simTask()
{
    while (running_) {
        /* Wait for 1 second or wake event */
        epicsEventWaitWithTimeout(wakeEvent_, 1.0);

        lock();
        simTime_ += 1.0;

        /* ── Temperature: slow drift with sinusoidal modulation ── */
        double temp = 25.0 + 2.0 * sin(simTime_ * 0.1) +
                      0.3 * sin(simTime_ * 0.5);
        setDoubleParam(P_Temperature, temp);

        /* ── Voltage readback: setpoint + small noise ──────────── */
        double sp;
        getDoubleParam(P_Voltage, &sp);
        int enabled;
        getIntegerParam(P_Enable, &enabled);
        double noise = (rand() / (double)RAND_MAX - 0.5) * 0.05;
        setDoubleParam(P_Voltage, enabled ? sp + noise : 0.0);

        /* ── Mode: auto-cycle through 4 modes ──────────────────── */
        int mode;
        getIntegerParam(P_Mode, &mode);
        if (simTime_ - modeCycle_ * 10.0 > 10.0) {
            mode = (mode + 1) % 4;
            setIntegerParam(P_Mode, mode);
            modeCycle_ = (int)(simTime_ / 10.0);
        }

        /* ── Waveform: generate sine wave ──────────────────────── */
        int nSamples;
        getIntegerParam(P_NumSamples, &nSamples);
        if (nSamples > (int)waveformSize_) {
            waveformBuf_ = (epicsFloat64 *)realloc(
                waveformBuf_, nSamples * sizeof(epicsFloat64));
            waveformSize_ = nSamples;
        }
        for (int i = 0; i < nSamples; i++) {
            double phase = (2.0 * M_PI * i) / nSamples;
            waveformBuf_[i] = 3.0 * sin(phase + simTime_ * 0.2) +
                              1.0 * sin(3.0 * phase);
        }
        /* Array callbacks are separate from scalar callbacks */
        doCallbacksFloat64Array(waveformBuf_, nSamples, P_Waveform, 0);

        /* ── Notify all scalar and string parameter changes ────── */
        callParamCallbacks();

        unlock();
    }
}
```

### 6.5 writeInt32 Override

Handles ENABLE, MODE, and NUM_SAMPLES writes:

```cpp
asynStatus simDriver::writeInt32(asynUser *pasynUser, epicsInt32 value)
{
    /* Let base class store the value in the parameter library */
    asynStatus status = asynPortDriver::writeInt32(pasynUser, value);
    if (status != asynSuccess) return status;

    if (pasynUser->reason == P_Enable) {
        /* Clamp to 0/1 */
        if (value < 0) value = 0;
        if (value > 1) value = 1;
        setIntegerParam(P_Enable, value);
        asynPrint(pasynUser, ASYN_TRACE_FLOW,
            "simDriver: ENABLE = %d\n", value);
    }
    else if (pasynUser->reason == P_Mode) {
        /* Clamp to valid range [0, 3] */
        if (value < 0) value = 0;
        if (value > 3) value = 3;
        setIntegerParam(P_Mode, value);
        /* Update the associated enum string */
        static const char *modeNames[] = {
            "Single", "Continuous", "External", "Burst"
        };
        setStringParam(P_Mode, modeNames[value]);
        asynPrint(pasynUser, ASYN_TRACE_FLOW,
            "simDriver: MODE = %d (%s)\n", value, modeNames[value]);
    }
    else if (pasynUser->reason == P_NumSamples) {
        if (value < 16)  value = 16;
        if (value > 65536) value = 65536;
        setIntegerParam(P_NumSamples, value);
        asynPrint(pasynUser, ASYN_TRACE_FLOW,
            "simDriver: NUM_SAMPLES = %d\n", value);
    }

    callParamCallbacks();
    return asynSuccess;
}
```

### 6.6 writeFloat64 Override

Handles VOLTAGE setpoint:

```cpp
asynStatus simDriver::writeFloat64(asynUser *pasynUser, epicsFloat64 value)
{
    asynStatus status = asynPortDriver::writeFloat64(pasynUser, value);
    if (status != asynSuccess) return status;

    if (pasynUser->reason == P_Voltage) {
        /* Clamp to valid range */
        if (value < 0.0)  value = 0.0;
        if (value > 10.0) value = 10.0;
        setDoubleParam(P_Voltage, value);
        asynPrint(pasynUser, ASYN_TRACE_FLOW,
            "simDriver: VOLTAGE = %.3f\n", value);
    }

    callParamCallbacks();
    return asynSuccess;
}
```

### 6.7 writeOctet Override

Handles MESSAGE writes:

```cpp
asynStatus simDriver::writeOctet(asynUser *pasynUser, const char *value,
                                  size_t nChars, size_t *nActual)
{
    asynStatus status = asynPortDriver::writeOctet(
        pasynUser, value, nChars, nActual);
    if (status != asynSuccess) return status;

    if (pasynUser->reason == P_Message) {
        /* Truncate to MAX_FILENAME_LENGTH (256) to fit stringin */
        size_t len = nChars;
        if (len > 255) len = 255;
        char buf[256];
        memcpy(buf, value, len);
        buf[len] = '\0';
        setStringParam(P_Message, buf);
        asynPrint(pasynUser, ASYN_TRACE_FLOW,
            "simDriver: MESSAGE = \"%s\"\n", buf);
    }

    callParamCallbacks();
    return asynSuccess;
}
```

### 6.8 readFloat64 Override

Returns computed values for VOLTAGE and TEMPERATURE. Called by `SCAN = "I/O Intr"` ai/ao records:

```cpp
asynStatus simDriver::readFloat64(asynUser *pasynUser, epicsFloat64 *value)
{
    if (pasynUser->reason == P_Temperature) {
        double temp, sp;
        getDoubleParam(P_Temperature, &temp);
        getDoubleParam(P_Voltage, &sp);
        /* Temperature rises 0.5°C per volt when enabled */
        int enabled;
        getIntegerParam(P_Enable, &enabled);
        *value = temp + (enabled ? sp * 0.5 : 0.0);
        return asynSuccess;
    }
    /* Default: return stored value from parameter library */
    return asynPortDriver::readFloat64(pasynUser, value);
}
```

### 6.9 readFloat64Array Override

Returns the waveform buffer. Called by `SCAN = "I/O Intr"` waveform records:

```cpp
asynStatus simDriver::readFloat64Array(asynUser *pasynUser,
                                        epicsFloat64 *value,
                                        size_t nElements, size_t *nIn)
{
    if (pasynUser->reason == P_Waveform) {
        int nSamples;
        getIntegerParam(P_NumSamples, &nSamples);
        size_t nCopy = (size_t)nSamples;
        if (nCopy > nElements) nCopy = nElements;
        memcpy(value, waveformBuf_, nCopy * sizeof(epicsFloat64));
        *nIn = nCopy;
        return asynSuccess;
    }
    return asynPortDriver::readFloat64Array(
        pasynUser, value, nElements, nIn);
}
```

### 6.10 readEnum Override

Returns enum strings for the MODE parameter. Called by mbbi/mbbo records:

```cpp
asynStatus simDriver::readEnum(asynUser *pasynUser, char *strings[],
                                int values[], int severities[],
                                size_t nElements, size_t *nIn)
{
    if (pasynUser->reason == P_Mode) {
        static const char *modeNames[] = {
            "Single", "Continuous", "External", "Burst"
        };
        size_t n = sizeof(modeNames) / sizeof(modeNames[0]);
        if (n > nElements) n = nElements;
        for (size_t i = 0; i < n; i++) {
            if (strings[i])
                strncpy(strings[i], modeNames[i], 40);
            if (values)
                values[i] = (int)i;
            if (severities)
                severities[i] = 0;  /* no alarm */
        }
        *nIn = n;
        return asynSuccess;
    }
    return asynPortDriver::readEnum(
        pasynUser, strings, values, severities, nElements, nIn);
}
```

### 6.11 IOC Shell Registration

The `simDriverConfigure` command creates driver instances from st.cmd:

```cpp
/* ── iocsh: simDriverConfigure("portName") ─────────────── */

extern "C" {

static const iocshArg simDriverArg0 = {"portName", iocshArgString};
static const iocshArg *simDriverArgs[] = {&simDriverArg0};
static const iocshFuncDef simDriverDef =
    {"simDriverConfigure", 1, simDriverArgs};

static void simDriverCallFunc(const iocshArgBuf *args)
{
    new simDriver(args[0].sval);
}

static void simDriverRegister(void)
{
    iocshRegister(&simDriverDef, simDriverCallFunc);
}
epicsExportRegistrar(simDriverRegister);

} /* extern "C" */
```

**Memory note:** The driver object allocated with `new` is owned by the asyn framework and must not be deleted. For clean shutdown with EPICS 7+, add `ASYN_DESTRUCTIBLE` to the asynFlags in the constructor and override `shutdownPortDriver()`. See the `asyn-port-driver` skill section 12 for details.

---

## 7. Database Template

Create `simIocApp/Db/simIoc.db`. This template uses macros for reusability across multiple port instances.

### 7.1 Template Macros

| Macro | Default | Purpose |
|-------|---------|---------|
| `P` | (required) | PV prefix |
| `R` | (required) | Record name prefix (e.g., `Demo:`) |
| `PORT` | (required) | asyn port name (matches `simDriverConfigure`) |
| `ADDR` | 0 | Device address |
| `TIMEOUT` | 0.5 | I/O timeout in seconds |
| `NELM` | 1024 | Waveform max elements |

### 7.2 Analog Output with Readback (ao / ai_RBV)

```
# ── Voltage Setpoint + Readback ──
record(ao, "$(P)$(R)Voltage") {
    field(DESC, "Voltage setpoint")
    field(DTYP, "asynFloat64")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))VOLTAGE")
    field(EGU,  "V")
    field(PREC, "3")
    field(DRVH, "10.0")
    field(DRVL, "0.0")
    field(HOPR, "10.0")
    field(LOPR, "0.0")
    field(PINI, "YES")
}
record(ai, "$(P)$(R)Voltage_RBV") {
    field(DESC, "Voltage readback")
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))VOLTAGE")
    field(EGU,  "V")
    field(PREC, "3")
    field(HOPR, "10.0")
    field(LOPR, "0.0")
    field(SCAN, "I/O Intr")
}
```

Key points:
- `PINI = "YES"` on the ao ensures the initial setpoint propagates to the driver at IOC startup
- `SCAN = "I/O Intr"` on the ai means it processes whenever the driver calls `callParamCallbacks()`
- Both records use the same `drvInfo` string (`VOLTAGE`); the driver distinguishes read from write via the virtual method dispatch

### 7.3 Read-Only Analog Input (ai)

```
# ── Temperature (read-only) ──
record(ai, "$(P)$(R)Temperature") {
    field(DESC, "Junction temperature")
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))TEMPERATURE")
    field(EGU,  "C")
    field(PREC, "2")
    field(HOPR, "50")
    field(LOPR, "0")
    field(HIHI, "45")
    field(HIGH, "40")
    field(LOW,  "5")
    field(LOLO, "0")
    field(HHSV, "MAJOR")
    field(HSV,  "MINOR")
    field(LSV,  "MINOR")
    field(LLSV, "MAJOR")
    field(SCAN, "I/O Intr")
}
```

Alarm limits are set on the EPICS record side. The driver only provides the raw value.

### 7.4 Binary Output with Readback (bo / bi_RBV)

```
# ── Enable/Disable ──
record(bo, "$(P)$(R)Enable") {
    field(DESC, "Output enable")
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))ENABLE")
    field(ZNAM, "Disable")
    field(ONAM, "Enable")
    field(PINI, "YES")
}
record(bi, "$(P)$(R)Enable_RBV") {
    field(DESC, "Enable readback")
    field(DTYP, "asynInt32")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))ENABLE")
    field(ZNAM, "Disabled")
    field(ONAM, "Enabled")
    field(SCAN, "I/O Intr")
}
```

Note the naming convention: `ZNAM="Disable"/ONAM="Enable"` (verb/action) on the bo vs. `ZNAM="Disabled"/ONAM="Enabled"` (adjective/state) on the bi. This is an EPICS convention, not enforced by the framework.

### 7.5 Multi-Bit Binary with Enums (mbbo / mbbi_RBV)

```
# ── Operating Mode ──
record(mbbo, "$(P)$(R)Mode") {
    field(DESC, "Operating mode")
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(ZRST, "Single")
    field(ONST, "Continuous")
    field(TWST, "External")
    field(THST, "Burst")
    field(PINI, "YES")
}
record(mbbi, "$(P)$(R)Mode_RBV") {
    field(DESC, "Mode readback")
    field(DTYP, "asynInt32")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(ZRST, "Single")
    field(ONST, "Continuous")
    field(TWST, "External")
    field(THST, "Burst")
    field(SCAN, "I/O Intr")
}
```

For mbbi/mbbo records, the DTYP is `"asynInt32"` (not `"asynUInt32Digital"`). This gives full 32-bit range with optional enum string mapping. When the driver overrides `readEnum()`, the strings can alternatively be provided at runtime rather than hardcoded in the .db file. See the `asyn-database` skill section 2.4 for the `asynUInt32Digital` alternative.

### 7.6 String Output with Readback (stringout / stringin_RBV)

```
# ── Message ──
record(stringout, "$(P)$(R)Message") {
    field(DESC, "Status message")
    field(DTYP, "asynOctetWrite")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MESSAGE")
    field(VAL,  "System ready")
    field(PINI, "YES")
}
record(stringin, "$(P)$(R)Message_RBV") {
    field(DESC, "Message readback")
    field(DTYP, "asynOctetRead")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MESSAGE")
    field(SCAN, "I/O Intr")
}
```

**Limit:** stringin/stringout records store up to 40 characters (MAX_STRING_SIZE). For longer strings, use lsi/lso records (up to 65535 characters) or waveform records with `FTVL="CHAR"`. See the `asyn-database` skill section 2.5 for the full octet DTYP reference.

### 7.7 Waveform (Float64 Array Input)

```
# ── Waveform (sine wave data) ──
record(waveform, "$(P)$(R)Waveform") {
    field(DESC, "Sine wave data")
    field(DTYP, "asynFloat64ArrayIn")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))WAVEFORM")
    field(FTVL, "DOUBLE")
    field(NELM, "$(NELM=1024)")
    field(SCAN, "I/O Intr")
}
```

Critical:
- `FTVL` must match the array element type. `"DOUBLE"` for Float64Array. Use `"FLOAT"` for Float32Array, `"LONG"` for Int32Array, `"SHORT"` for Int16Array, `"CHAR"` for Int8Array.
- `NELM` limits the maximum elements. The driver sets the actual count via the `nIn` output parameter.
- Waveform records can use `FTVL = "CHAR"` for byte arrays (e.g., from `asynOctetRead` or `asynInt8ArrayIn`).

### 7.8 Integer Output with Readback (longout / longin_RBV)

```
# ── Number of waveform samples ──
record(longout, "$(P)$(R)NumSamples") {
    field(DESC, "Waveform sample count")
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))NUM_SAMPLES")
    field(DRVH, "65536")
    field(DRVL, "16")
    field(PINI, "YES")
}
record(longin, "$(P)$(R)NumSamples_RBV") {
    field(DESC, "Sample count readback")
    field(DTYP, "asynInt32")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))NUM_SAMPLES")
    field(SCAN, "I/O Intr")
}
```

---

## 8. Startup Script

### 8.1 Complete st.cmd

Edit `iocBoot/iocSimIoc/st.cmd`:

```bash
#!../../bin/linux-x86_64/simIoc

< envPaths

cd "${TOP}"

## ── 1. Register all support components ──
dbLoadDatabase "dbd/simIoc.dbd"
simIoc_registerRecordDeviceDriver pdbbase

## ── 2. Create the simulated driver port ──
simDriverConfigure("SIM1")

## ── 3. Load record instances ──
dbLoadRecords("db/simIoc.db", "P=SIM:,R=Demo:,PORT=SIM1,ADDR=0,TIMEOUT=0.5,NELM=1024")

## ── 4. asynRecord for diagnostics (optional, requires asyn module) ──
# dbLoadRecords("db/asynRecord.db", "P=SIM:,R=Demo:Asyn,PORT=SIM1,ADDR=0,OMAX=256,IMAX=256")

## ── 5. Initialize the IOC ──
cd "${TOP}/iocBoot/${IOC}"
iocInit

## ── 6. Post-init commands ──
dbl > "${TOP}/records.dbl"
```

### 8.2 Command Ordering Rules

The order is mandatory. Deviating from this order causes failures:

| Step | Command | What It Does |
|------|---------|--------------|
| 1 | `dbLoadDatabase` + `registerRecordDeviceDriver` | Loads DBD, registers all record types, device support, drivers, and iocsh commands |
| 2 | `simDriverConfigure("SIM1")` | Creates the asyn port. Must happen after registration (otherwise iocsh doesn't know the command) |
| 3 | `dbLoadRecords(...)` | Loads record instances. DTYP strings are validated against registered device support |
| 4 | `iocInit` | Initializes the IOC. Records with `PINI=YES` process once, sending initial values to the driver |

See the `asyn-port-config` skill for the full port configuration rules including IP/serial transports, trace/debug commands, and EOS settings.

---

## 9. Parameter Type to Record Type Mapping

Quick-reference: which EPICS record types and DTYP strings to use for each asyn parameter type.

### 9.1 Scalar Types

| asynParamType | DTYP Strings | Input Records | Output Records |
|---|---|---|---|
| `asynParamInt32` | `"asynInt32"`, `"asynInt32Average"` | ai, bi, longin, mbbi | ao, bo, longout, mbbo |
| `asynParamInt64` | `"asynInt64"` | ai, longin, int64in | ao, longout, int64out |
| `asynParamFloat64` | `"asynFloat64"`, `"asynFloat64Average"` | ai | ao |
| `asynParamOctet` | `"asynOctetRead"`, `"asynOctetWrite"`, `"asynOctetCmdResponse"`, `"asynOctetWriteRead"`, `"asynOctetWriteBinary"` | stringin, waveform, lsi | stringout, lso, waveform, printf, scalcout |
| `asynParamUInt32Digital` | `"asynUInt32Digital"` | bi, longin, mbbi, mbbiDirect | bo, longout, mbbo, mbboDirect |

### 9.2 Array Types

| asynParamType | DTYP Strings | Input Records | Output Records |
|---|---|---|---|
| `asynParamInt8Array` | `"asynInt8ArrayIn"`, `"asynInt8ArrayOut"` | waveform, aai | waveform, aao |
| `asynParamInt16Array` | `"asynInt16ArrayIn"`, `"asynInt16ArrayOut"` | waveform, aai | waveform, aao |
| `asynParamInt32Array` | `"asynInt32ArrayIn"`, `"asynInt32ArrayOut"` | waveform, aai | waveform, aao |
| `asynParamInt64Array` | `"asynInt64ArrayIn"`, `"asynInt64ArrayOut"` | waveform, aai | waveform, aao |
| `asynParamFloat32Array` | `"asynFloat32ArrayIn"`, `"asynFloat32ArrayOut"` | waveform, aai | waveform, aao |
| `asynParamFloat64Array` | `"asynFloat64ArrayIn"`, `"asynFloat64ArrayOut"` | waveform, aai | waveform, aao |

### 9.3 FTVL for Waveform Records

| asynParamType | FTVL Value |
|---|---|
| `asynParamInt8Array` | `"CHAR"` |
| `asynParamInt16Array` | `"SHORT"` |
| `asynParamInt32Array` | `"LONG"` |
| `asynParamInt64Array` | `"INT64"` |
| `asynParamFloat32Array` | `"FLOAT"` |
| `asynParamFloat64Array` | `"DOUBLE"` |

See the `asyn-database` skill section 2 for the complete DTYP reference and the `epics-database` skill for per-record-type field details.

---

## 10. Common PV Patterns

### 10.1 Setpoint/Readback (_RBV)

The EPICS convention: output records set the desired value; input records with `_RBV` suffix read back the actual hardware state. Both use the same `drvInfo` string but different DTYP directions:

```
record(ao, "$(P)$(R)Voltage")    { ... field(OUT, "...") field(PINI, "YES") }
record(ai, "$(P)$(R)Voltage_RBV") { ... field(INP, "...") field(SCAN, "I/O Intr") }
```

**When to use PINI:** Always on output records (`ao`, `bo`, `mbbo`, `stringout`, `longout`). Without `PINI="YES"`, the record holds the default value until an operator writes, and the driver never receives the initial setpoint.

**When to use I/O Intr:** On readback records when the driver actively generates data (background thread, interrupt handler, or hardware polling). The driver's `callParamCallbacks()` triggers the record to process. Without `I/O Intr`, the record only processes when scanned or explicitly processed.

### 10.2 Binary Naming Convention

```
record(bo, "...")  { field(ZNAM, "Disable")  field(ONAM, "Enable") }     # Verb form (what this does)
record(bi, "...")  { field(ZNAM, "Disabled") field(ONAM, "Enabled") }    # Adjective form (what it is)
```

This is a convention, not enforced. It distinguishes the action (output) from the observed state (input).

### 10.3 Multi-Bit Binary with Enum Strings

Two approaches:

**Static enums in database:** Define `ZRST`/`ONST`/`TWST`/`THST`... in the .db file. Works when the enum values are fixed and known at design time. The driver's `readEnum()` override is optional.

**Dynamic enums from driver:** Override `readEnum()` in the driver to provide enums at runtime. Works when enum values depend on driver state or hardware capabilities. The .db strings act as fallbacks.

The simDriver example uses static enums in the .db file but also overrides `readEnum()` for illustration.

### 10.4 Array Handling with NELM and FTVL

```
record(waveform, "$(P)Waveform") {
    field(FTVL, "DOUBLE")              # MUST match array element type
    field(NELM, "$(NELM=1024)")        # Max elements (capacity)
    field(SCAN, "I/O Intr")
}
```

- `NELM`: maximum capacity. The driver can deliver fewer elements via `nIn`.
- `FTVL`: must match the asyn array type exactly. Mismatch causes silent garbage data.
- `NORD`: set by the driver at runtime (via `nIn`). Read-only from the record's perspective.
- Array callbacks use `doCallbacksFloat64Array()` (or equivalent) — separate from `callParamCallbacks()`.

### 10.5 I/O Intr vs Periodic Scan

| Scan Type | When to Use | Driver Requirement |
|---|---|---|
| `I/O Intr` | Value changes asynchronously (background thread, hardware IRQ) | `interruptMask` must include the parameter's interface; driver must call `callParamCallbacks()` |
| `"1 second"` (periodic) | Polling at known rate | Driver stores value in parameter library; record polls via `readXxx()` |
| `Passive` | Processed only by links or explicit `dbpf` | N/A |

**For averaging DTYP (`asynInt32Average`, `asynFloat64Average`):** Use periodic scan, not I/O Intr. These DTYP drivers accumulate multiple read calls and emit the average.

---

## 11. Complete Files Listing

Summary of every file to create or edit, with references to the section where each appears:

| File | Action | Section |
|------|--------|---------|
| `configure/RELEASE` | Edit — add ASYN path | 3 |
| `simIocApp/src/Makefile` | Edit — combined library+IOC | 4 |
| `simIocApp/src/simDriver.h` | Create — driver header | 6.2 |
| `simIocApp/src/simDriver.cpp` | Create — driver implementation | 6.3–6.11 |
| `simIocApp/src/simDriver.dbd` | Create — registrar fragment | 5.1 |
| `simIocApp/Db/Makefile` | Edit — add `DB += simIoc.db` | 4.3 |
| `simIocApp/Db/simIoc.db` | Create — database template | 7 |
| `iocBoot/iocSimIoc/st.cmd` | Edit — port config, record loading | 8 |

After creating/editing all files:

```bash
make
cd iocBoot/iocSimIoc
./st.cmd
```

At the IOC shell, verify:

```
epics> dbl
SIM:Demo:Voltage
SIM:Demo:Voltage_RBV
SIM:Demo:Temperature
SIM:Demo:Enable
SIM:Demo:Enable_RBV
SIM:Demo:Mode
SIM:Demo:Mode_RBV
SIM:Demo:Message
SIM:Demo:Message_RBV
SIM:Demo:Waveform
SIM:Demo:NumSamples
SIM:Demo:NumSamples_RBV
```

Test with Channel Access:
```bash
caget SIM:Demo:Temperature       # Should change each second (~25°C ± 2°C)
caget SIM:Demo:Waveform          # 1024-element sine wave
caput SIM:Demo:Voltage 5.0       # Set voltage
caget SIM:Demo:Voltage_RBV       # Should read back ~5.0 with noise
caput SIM:Demo:Enable Enable     # Enable output
caput SIM:Demo:Mode Continuous   # Change mode
caput SIM:Demo:Message "Hello"   # Write message
```

---

## 12. Key Rules and Pitfalls

1. **Always call `callParamCallbacks()` after `setXxxParam()`.** Without it, I/O Intr records never see the updated value. The callbacks are NOT automatic — they are opt-in by the driver author. This is the single most common bug in asyn driver development.

2. **Array callbacks are separate from scalar callbacks.** `callParamCallbacks()` handles scalars (Int32, Float64) and strings (Octet). Array types need explicit `doCallbacksFloat64Array()` (or `doCallbacksInt32Array()`, `doCallbacksInt8Array()`, etc.). Forgetting array callbacks results in waveform records showing stale data.

3. **`lock()`/`unlock()` only in background threads.** Virtual method overrides (`writeInt32`, `readFloat64`, etc.) are called with the asyn mutex already held. Calling `lock()` inside them nests the mutex (it's recursive, so it doesn't deadlock, but it's unnecessary and confusing).

4. **`interfaceMask` must include every interface used.** If `createParam()` uses `asynParamFloat64`, then `asynFloat64Mask` must be in the constructor's `interfaceMask`. Missing masks cause parameters to be inaccessible. The interface mask also determines which `readXxx()`/`writeXxx()` virtual methods the framework dispatches to.

5. **`interruptMask` enables I/O Intr.** Records with `SCAN = "I/O Intr"` require the corresponding mask. If a parameter is in `interfaceMask` but not `interruptMask`, its records will not process on `callParamCallbacks()` (though direct reads still work). In most cases, set `interruptMask` to match `interfaceMask`.

6. **DTYP must match the asyn interface type.** `"asynFloat64"` for `asynParamFloat64`, `"asynInt32"` for `asynParamInt32`, `"asynFloat64ArrayIn"` for `asynParamFloat64Array`, etc. A mismatched DTYP silently produces zero values or stale data — EPICS does not warn about type mismatches at record load time.

7. **FTVL must match the array element type.** `FTVL = "DOUBLE"` for `asynFloat64ArrayIn/Out`, `FTVL = "CHAR"` for `asynInt8ArrayIn/Out`. A mismatch between FTVL and the driver's array type produces garbled data.

8. **drvInfo strings are case-sensitive and must match exactly.** `"VOLTAGE"` in `createParam()` must match `"VOLTAGE"` in the INP/OUT link. `"voltage"` or `"Voltage"` will fail silently.

9. **st.cmd ordering is mandatory.** The sequence is: (1) `dbLoadDatabase` + `registerRecordDeviceDriver`, (2) configure drivers/ports, (3) `dbLoadRecords`, (4) `iocInit`. Swapping (2) and (3) causes "device support not found" errors at record load time. Calling `dbLoadRecords` before `registerRecordDeviceDriver` fails because the DTYP strings cannot be resolved.

10. **`PINI = "YES"` on output records** ensures the initial setpoint reaches the driver at `iocInit`. Without it, the record holds its default value until an operator writes. This is critical for defaults like voltage limits, enable states, and operating modes.

11. **Unused parameters consume resources.** Each `createParam()` allocates storage and creates an asyn parameter node. For large multi-channel drivers, consider creating parameters per-channel only when that channel is present (based on hardware detection).

12. **Case sensitivity in enum strings matters.** The mbbi/mbbo `ZRST`/`ONST`/... strings in the .db file must match what the driver returns in `readEnum()`. If they differ, Channel Access clients see inconsistent state — the numeric VAL will be correct but the string representation may mismatch.

13. **Driver objects allocated with `new` in iocsh configure functions are owned by asynManager.** The framework manages their lifecycle. For clean shutdown with EPICS 7+, use the `ASYN_DESTRUCTIBLE` flag and override `shutdownPortDriver()` to stop threads and free resources. See the `asyn-port-driver` skill section 12.

14. **The `reason` field in `pasynUser` is your parameter index.** It is set by the framework from the drvInfo string in the INP/OUT link. Compare it to your `P_Xxx` members to identify which parameter is being accessed. Parameter indices are stable across the driver's lifetime.
