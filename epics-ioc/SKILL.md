---
name: epics-ioc
description: Create a complete EPICS IOC from scratch — C device support (dset) and C++ asynPortDriver approaches, covering analog, binary, multi-bit, string, waveform, and array PV types
---

# EPICS IOC Skill

You are an expert at creating complete EPICS IOC applications. You choose between two approaches: traditional C device support with `dset` tables for simple synchronous hardware, or C++ `asynPortDriver` for complex/asynchronous instruments. You know how to assemble all five layers (build, driver, DBD, database, startup) and where to find detailed reference for each.

---

## 1. Choosing an Approach

| Factor | C Device Support (dset) | C++ asynPortDriver |
|--------|------------------------|---------------------|
| Language | C | C++ |
| Complexity | Simple, synchronous I/O | Complex, async, multi-parameter |
| Dependencies | None (base only) | Requires asyn module |
| Boilerplate | Minimal | Parameter library, mutex, thread |
| Record types | One dset per record type | One class handles all types |
| IOC shell config | Manual iocsh registration | Standard iocsh pattern |
| Reference skill | `epics-device-support` | `asyn-port-driver` |

**Rule of thumb:** Hardware that responds instantly to reads/writes → C dset. Hardware with background polling, many parameters, or async behavior → asynPortDriver.

---

## 2. Approach A: C Device Support (dset)

For simple hardware where `read_ai()` directly samples a register or `write_ao()` directly sets a DAC.

### 2.1 Minimal DBD Declaration

```
# myDevSup.dbd
device(ai, INST_IO, devAiMyDev, "My Device AI")
device(ao, INST_IO, devAoMyDev, "My Device AO")
device(bi, INST_IO, devBiMyDev, "My Device BI")
device(bo, INST_IO, devBoMyDev, "My Device BO")
device(waveform, INST_IO, devWfMyDev, "My Device Waveform")
```

### 2.2 Minimal dset and Device Support (C)

```c
/* devAiMyDev.c — Synchronous AI device support */
#include "aiRecord.h"
#include "devSup.h"
#include "epicsExport.h"

static long init_record(dbCommon *pcommon) {
    aiRecord *prec = (aiRecord *)pcommon;
    if (prec->inp.type != INST_IO) return -1;
    /* Parse prec->inp.value.instio.string for hardware address */
    return 0;
}

static long read_ai(aiRecord *prec) {
    /* Sample hardware, write to prec->val */
    prec->val = readHardwareChannel(prec->dpvt);
    return 0;
}

static long special_linconv(aiRecord *prec, int after) {
    /* Optional linear conversion: EGUL/EGUF → EGU */
    return 0;
}

aidset devAiMyDev = {6, NULL, NULL, init_record, NULL, read_ai, special_linconv};
epicsExportAddress(dset, devAiMyDev);
```

The pattern repeats for ao (`aodset` with `write_ao`), bi (`bidset` with `read_bi`), bo (`bodset` with `write_bo`), waveform (`waveformdset` with `read_wf`), etc.

**Details:** See the `epics-device-support` skill for all 20+ dset types, init/read/write signatures, async processing with callbacks, I/O Intr scanning, iocsh registration, and sub/aSub functions.

### 2.3 DBD for the IOC

```
# simIoc.dbd (assembled by Makefile from fragments)
include "base.dbd"
include "myDevSup.dbd"
```

### 2.4 Database Records for C Device Support

Same format as asyn but uses `INST_IO` links without the `@asyn()` wrapper:

```
record(ai, "$(P)Voltage") {
    field(DTYP, "My Device AI")
    field(INP,  "@channel=0")
    field(SCAN, "1 second")
}
```

The INP string is parsed by `init_record`. See the `epics-database` skill for per-record-type field details.

---

## 3. Approach B: C++ asynPortDriver

For instruments with background polling, many parameters, or the need for I/O Intr scan. A single driver class handles all parameter types.

### 3.1 Minimal DBD Declaration

```
# simDriver.dbd
registrar(simDriverRegister)
```

### 3.2 Minimal Driver Header

```cpp
#include <asynPortDriver.h>

#define P_VoltageString     "VOLTAGE"
#define P_TemperatureString "TEMPERATURE"
#define P_EnableString      "ENABLE"
#define P_ModeString        "MODE"
#define P_WaveformString    "WAVEFORM"

class simDriver : public asynPortDriver {
public:
    simDriver(const char *portName);
    virtual asynStatus writeInt32(asynUser *pasynUser, epicsInt32 value);
    virtual asynStatus writeFloat64(asynUser *pasynUser, epicsFloat64 value);
    virtual asynStatus writeOctet(asynUser *pasynUser, const char *value,
                                  size_t nChars, size_t *nActual);
    virtual asynStatus readFloat64(asynUser *pasynUser, epicsFloat64 *value);
    virtual asynStatus readFloat64Array(asynUser *pasynUser,
                                        epicsFloat64 *value,
                                        size_t nElements, size_t *nIn);
    virtual asynStatus readEnum(asynUser *pasynUser, char *strings[],
                                int values[], int severities[],
                                size_t nElements, size_t *nIn);
private:
    void simTask();
    static void simTaskC(void *p);

    /* Parameter indices */
    int P_Voltage;
    int P_Temperature;
    int P_Enable;
    int P_Mode;
    int P_Waveform;

    epicsEventId wakeEvent_;
    bool running_;
    epicsFloat64 *waveformBuf_;
    size_t waveformSize_;
};
```

### 3.3 Minimal Constructor + Background Thread

```cpp
simDriver::simDriver(const char *portName)
    : asynPortDriver(portName, 1,
        asynInt32Mask | asynFloat64Mask | asynOctetMask |
        asynFloat64ArrayMask | asynEnumMask | asynDrvUserMask,
        asynInt32Mask | asynFloat64Mask | asynOctetMask |
        asynFloat64ArrayMask | asynEnumMask,
        0, 1, 0, 0)
    , wakeEvent_(epicsEventCreate(epicsEventEmpty))
    , running_(true)
    , waveformBuf_(NULL)
    , waveformSize_(1024)
{
    /* ── Create parameters for each signal ── */
    createParam(P_VoltageString,     asynParamFloat64,      &P_Voltage);
    createParam(P_TemperatureString, asynParamFloat64,      &P_Temperature);
    createParam(P_EnableString,      asynParamInt32,        &P_Enable);
    createParam(P_ModeString,        asynParamInt32,        &P_Mode);
    createParam(P_WaveformString,    asynParamFloat64Array, &P_Waveform);

    /* ── Set initial values ── */
    setDoubleParam(P_Voltage,     0.0);
    setDoubleParam(P_Temperature, 25.0);
    setIntegerParam(P_Enable,     0);
    setIntegerParam(P_Mode,       0);
    setStringParam(P_Mode,        "Single");

    waveformBuf_ = (epicsFloat64 *)calloc(waveformSize_, sizeof(epicsFloat64));

    /* ── Launch background thread ── */
    epicsThreadCreate("simTask", epicsThreadPriorityMedium,
        epicsThreadGetStackSize(epicsThreadStackMedium), simTaskC, this);
}
```

### 3.4 Key Override Patterns

```cpp
/* writeInt32 — handle binary, multi-bit, and integer writes */
asynStatus simDriver::writeInt32(asynUser *pasynUser, epicsInt32 value)
{
    asynPortDriver::writeInt32(pasynUser, value);
    if (pasynUser->reason == P_Enable) {
        value = (value ? 1 : 0);
        setIntegerParam(P_Enable, value);
    } else if (pasynUser->reason == P_Mode) {
        value = (value < 0 ? 0 : (value > 3 ? 3 : value));
        setIntegerParam(P_Mode, value);
        const char *names[] = {"Single","Continuous","External","Burst"};
        setStringParam(P_Mode, names[value]);
    }
    callParamCallbacks();
    return asynSuccess;
}

/* writeFloat64 — handle analog setpoint writes */
asynStatus simDriver::writeFloat64(asynUser *pasynUser, epicsFloat64 value)
{
    asynPortDriver::writeFloat64(pasynUser, value);
    if (pasynUser->reason == P_Voltage) {
        if (value < 0.0) value = 0.0;
        if (value > 10.0) value = 10.0;
        setDoubleParam(P_Voltage, value);
    }
    callParamCallbacks();
    return asynSuccess;
}

/* writeOctet — handle string writes */
asynStatus simDriver::writeOctet(asynUser *pasynUser, const char *value,
                                  size_t nChars, size_t *nActual)
{
    asynPortDriver::writeOctet(pasynUser, value, nChars, nActual);
    if (pasynUser->reason == P_Mode) {
        char buf[256];
        size_t n = (nChars < 255) ? nChars : 255;
        memcpy(buf, value, n); buf[n] = '\0';
        setStringParam(P_Mode, buf);
    }
    callParamCallbacks();
    return asynSuccess;
}

/* readFloat64 — computed readback (called by I/O Intr records) */
asynStatus simDriver::readFloat64(asynUser *pasynUser, epicsFloat64 *value)
{
    if (pasynUser->reason == P_Temperature) {
        double temp; getDoubleParam(P_Temperature, &temp);
        int en; getIntegerParam(P_Enable, &en);
        double sp; getDoubleParam(P_Voltage, &sp);
        *value = temp + (en ? sp * 0.5 : 0.0);
        return asynSuccess;
    }
    return asynPortDriver::readFloat64(pasynUser, value);
}

/* readFloat64Array — waveform data (called by I/O Intr waveform records) */
asynStatus simDriver::readFloat64Array(asynUser *pasynUser,
                                        epicsFloat64 *value,
                                        size_t nElements, size_t *nIn)
{
    size_t n = (waveformSize_ < nElements) ? waveformSize_ : nElements;
    memcpy(value, waveformBuf_, n * sizeof(epicsFloat64));
    *nIn = n;
    return asynSuccess;
}

/* readEnum — mbbi/mbbo enum strings */
asynStatus simDriver::readEnum(asynUser *pasynUser, char *strings[],
                                int values[], int severities[],
                                size_t nElements, size_t *nIn)
{
    const char *names[] = {"Single","Continuous","External","Burst"};
    size_t n = (sizeof(names)/sizeof(names[0]) < nElements)
               ? sizeof(names)/sizeof(names[0]) : nElements;
    for (size_t i = 0; i < n; i++) {
        if (strings[i]) strncpy(strings[i], names[i], 40);
    }
    *nIn = n;
    return asynSuccess;
}
```

### 3.5 Background Thread Pattern

```cpp
void simDriver::simTask()
{
    double simTime = 0.0;
    while (running_) {
        epicsEventWaitWithTimeout(wakeEvent_, 1.0);
        lock();
        simTime += 1.0;

        /* Update computed values */
        double temp = 25.0 + 2.0 * sin(simTime * 0.1);
        setDoubleParam(P_Temperature, temp);

        /* Generate waveform */
        int ns = (int)waveformSize_;
        for (int i = 0; i < ns; i++)
            waveformBuf_[i] = 3.0 * sin(2.0 * M_PI * i / ns + simTime * 0.2);

        /* CRITICAL: array callbacks separate from scalar callbacks */
        doCallbacksFloat64Array(waveformBuf_, ns, P_Waveform, 0);
        callParamCallbacks();    /* Scalar + string */
        unlock();
    }
}
```

### 3.6 IOC Shell Registration

```cpp
extern "C" {
static const iocshArg arg0 = {"portName", iocshArgString};
static const iocshArg *args[] = {&arg0};
static const iocshFuncDef def = {"simDriverConfigure", 1, args};
static void callFunc(const iocshArgBuf *a) { new simDriver(a[0].sval); }
static void simDriverRegister(void) { iocshRegister(&def, callFunc); }
epicsExportRegistrar(simDriverRegister);
}
```

**Details:** See the `asyn-port-driver` skill for all parameter types, interface masks, virtual method signatures, threading patterns, trace logging, and destructor/shutdown.

---

## 4. Build System

Both approaches use `makeBaseApp.pl` and the same directory structure:

```bash
makeBaseApp.pl -t ioc simIoc       # Create application directories
makeBaseApp.pl -i -t ioc simIoc    # Create iocBoot directories
```

### 4.1 configure/RELEASE

```makefile
# For C dset approach (no extra dependencies):
EPICS_BASE = /path/to/epics/base

# For asynPortDriver approach (add asyn):
ASYN = /path/to/asyn
EPICS_BASE = /path/to/epics/base

-include $(TOP)/configure/RELEASE.local
```

### 4.2 src/Makefile — C dset Approach

```makefile
TOP=../..
include $(TOP)/configure/CONFIG

PROD_IOC = simIoc
DBD += simIoc.dbd
simIoc_DBD += base.dbd
simIoc_DBD += devMyDev.dbd       # Device support DBD

simIoc_SRCS += simIoc_registerRecordDeviceDriver.cpp
simIoc_SRCS += devAiMyDev.c       # Device support source files
simIoc_SRCS += devAoMyDev.c
simIoc_SRCS += devWfMyDev.c

simIoc_SRCS_DEFAULT += simIocMain.cpp
simIoc_SRCS_vxWorks += -nil-
simIoc_LIBS += $(EPICS_BASE_IOC_LIBS)

include $(TOP)/configure/RULES
```

### 4.3 src/Makefile — asynPortDriver Approach

```makefile
TOP=../..
include $(TOP)/configure/CONFIG

USR_CPPFLAGS += -DUSE_TYPED_RSET -DUSE_TYPED_DSET

# Support library
LIBRARY_IOC += simDriver
DBD += simDriver.dbd
simDriver_SRCS += simDriver.cpp
simDriver_LIBS += asyn
simDriver_LIBS += $(EPICS_BASE_IOC_LIBS)

# IOC application
PROD_IOC = simIoc
DBD += simIoc.dbd
simIoc_DBD += base.dbd
simIoc_DBD += asyn.dbd
simIoc_DBD += simDriver.dbd

simIoc_SRCS += simIoc_registerRecordDeviceDriver.cpp
simIoc_SRCS_DEFAULT += simIocMain.cpp
simIoc_SRCS_vxWorks += -nil-
simIoc_LIBS += simDriver
simIoc_LIBS += asyn
simIoc_LIBS += $(EPICS_BASE_IOC_LIBS)

include $(TOP)/configure/RULES
```

**Details:** See the `epics-module` skill for full Makefile variable reference, version generation, test programs, and all build system options.

---

## 5. Database Records

### 5.1 C dset Approach (INST_IO Links)

```
record(ai, "$(P)Voltage") {
    field(DTYP, "My Device AI")
    field(INP,  "@channel=0")
    field(EGU,  "V")
    field(SCAN, "1 second")
}

record(ao, "$(P)Setpoint") {
    field(DTYP, "My Device AO")
    field(OUT,  "@channel=1")
    field(DRVH, "10.0")
    field(DRVL, "0.0")
    field(PINI, "YES")
}

record(waveform, "$(P)Waveform") {
    field(DTYP, "My Device Waveform")
    field(INP,  "@channel=0")
    field(FTVL, "DOUBLE")
    field(NELM, "1024")
    field(SCAN, "1 second")
}
```

### 5.2 asynPortDriver Approach (@asyn Links)

```
record(ao, "$(P)$(R)Voltage") {
    field(DTYP, "asynFloat64")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))VOLTAGE")
    field(EGU,  "V")
    field(DRVH, "10.0")
    field(DRVL, "0.0")
    field(PINI, "YES")
}
record(ai, "$(P)$(R)Voltage_RBV") {
    field(DTYP, "asynFloat64")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))VOLTAGE")
    field(EGU,  "V")
    field(SCAN, "I/O Intr")
}

record(bo, "$(P)$(R)Enable") {
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))ENABLE")
    field(ZNAM, "Disable")
    field(ONAM, "Enable")
    field(PINI, "YES")
}
record(bi, "$(P)$(R)Enable_RBV") {
    field(DTYP, "asynInt32")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))ENABLE")
    field(ZNAM, "Disabled")
    field(ONAM, "Enabled")
    field(SCAN, "I/O Intr")
}

record(mbbo, "$(P)$(R)Mode") {
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(ZRST, "Single")
    field(ONST, "Continuous")
    field(TWST, "External")
    field(THST, "Burst")
    field(PINI, "YES")
}
record(mbbi, "$(P)$(R)Mode_RBV") {
    field(DTYP, "asynInt32")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(ZRST, "Single")
    field(ONST, "Continuous")
    field(TWST, "External")
    field(THST, "Burst")
    field(SCAN, "I/O Intr")
}

record(stringout, "$(P)$(R)Message") {
    field(DTYP, "asynOctetWrite")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(PINI, "YES")
}
record(stringin, "$(P)$(R)Message_RBV") {
    field(DTYP, "asynOctetRead")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))MODE")
    field(SCAN, "I/O Intr")
}

record(waveform, "$(P)$(R)Waveform") {
    field(DTYP, "asynFloat64ArrayIn")
    field(INP,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))WAVEFORM")
    field(FTVL, "DOUBLE")
    field(NELM, "$(NELM=1024)")
    field(SCAN, "I/O Intr")
}

record(longout, "$(P)$(R)NumSamples") {
    field(DTYP, "asynInt32")
    field(OUT,  "@asyn($(PORT),$(ADDR=0),$(TIMEOUT=0.5))NUM_SAMPLES")
    field(PINI, "YES")
}
```

### 5.3 PV Type Coverage Summary

| PV Type | Record Pair | asyn DTYP | C dset |
|---|---|---|---|
| Analog | ao / ai (_RBV) | `"asynFloat64"` | `aodset` / `aidset` |
| Binary | bo / bi (_RBV) | `"asynInt32"` | `bodset` / `bidset` |
| Multi-bit | mbbo / mbbi (_RBV) | `"asynInt32"` | `mbbodset` / `mbbidset` |
| Integer | longout / longin (_RBV) | `"asynInt32"` | `longoutdset` / `longindset` |
| String | stringout / stringin (_RBV) | `"asynOctetWrite"` / `"asynOctetRead"` | `stringoutdset` / `stringindset` |
| Waveform | waveform | `"asynFloat64ArrayIn"` | `waveformdset` |
| Array (in) | aai | `"asynFloat64ArrayIn"` | `aaidset` |
| Array (out) | aao | `"asynFloat64ArrayOut"` | `aaodset` |

**Details:** See the `epics-database` skill for full record type field references (30+ types). See the `asyn-database` skill for complete asyn DTYP reference and setpoint/readback patterns.

---

## 6. Startup Script (st.cmd)

### 6.1 C dset Approach

```bash
< envPaths
cd "${TOP}"
dbLoadDatabase "dbd/simIoc.dbd"
simIoc_registerRecordDeviceDriver pdbbase

dbLoadRecords("db/simIoc.db", "P=SIM:,R=Demo:")

cd "${TOP}/iocBoot/${IOC}"
iocInit
```

### 6.2 asynPortDriver Approach

```bash
< envPaths
cd "${TOP}"
dbLoadDatabase "dbd/simIoc.dbd"
simIoc_registerRecordDeviceDriver pdbbase

# Create driver port before loading records
simDriverConfigure("SIM1")

# Load records using the driver port
dbLoadRecords("db/simIoc.db", "P=SIM:,R=Demo:,PORT=SIM1,ADDR=0,TIMEOUT=0.5,NELM=1024")
# Optional: dbLoadRecords("db/asynRecord.db", "P=SIM:,R=Demo:Asyn,PORT=SIM1,ADDR=0,OMAX=256,IMAX=256")

cd "${TOP}/iocBoot/${IOC}"
iocInit
```

### 6.3 Ordering Rules (Both Approaches)

1. `dbLoadDatabase` + `registerRecordDeviceDriver` — registers all record types, device support, and iocsh commands
2. Configure drivers/ports (asynPortDriver only) — must happen after registration so iocsh knows the command
3. `dbLoadRecords` — record DTYP strings validated against registered device support
4. `iocInit` — records with `PINI=YES` process once, sending initial values to hardware

**Details:** See the `asyn-port-config` skill for IP/serial/trace/EOS configuration. See the `epics-module` skill section 9 for the full st.cmd reference.

---

## 7. Complete File Checklist

### C dset IOC
| File | Action |
|------|--------|
| `configure/RELEASE` | Edit — set EPICS_BASE |
| `simIocApp/src/Makefile` | Edit — PROD_IOC, DBD, SRCS |
| `simIocApp/src/devAiMyDev.c` | Create — per-record-type device support |
| `simIocApp/src/devAiMyDev.dbd` | Create — `device()` declarations |
| `simIocApp/Db/simIoc.db` | Create — records with INST_IO links |
| `iocBoot/iocSimIoc/st.cmd` | Edit — load DBD and records |

### asynPortDriver IOC
| File | Action |
|------|--------|
| `configure/RELEASE` | Edit — set ASYN + EPICS_BASE |
| `simIocApp/src/Makefile` | Edit — combined library+IOC |
| `simIocApp/src/simDriver.h` | Create — driver header |
| `simIocApp/src/simDriver.cpp` | Create — driver + iocsh registration |
| `simIocApp/src/simDriver.dbd` | Create — `registrar()` declaration |
| `simIocApp/Db/simIoc.db` | Create — records with @asyn links |
| `iocBoot/iocSimIoc/st.cmd` | Edit — port config + record loading |

---

## 8. Key Rules and Pitfalls

1. **IOC shell commands must be registered before use.** `dbLoadDatabase` + `registerRecordDeviceDriver` runs before `simDriverConfigure` in st.cmd. If you swap them, the iocsh shell doesn't know the command and fails.

2. **`dbLoadRecords` after driver configuration.** For asyn, records with `@asyn(portName, ...)` links require the port to exist at load time. For C dset, records can be loaded before hardware init (hardware is accessed at `iocInit`).

3. **C dset: `number` field must be correct.** The first field in every dset is the total function count (4 common + N record-specific). Wrong count → crash or silent corruption. See the `epics-device-support` skill section 1.2 for the table.

4. **asyn: `callParamCallbacks()` is mandatory after any `setXxxParam()`.** Without it, I/O Intr records never see the update. Array types additionally require explicit `doCallbacksFloat64Array()` (or equivalent).

5. **asyn: `lock()`/`unlock()` only in background threads.** Virtual method overrides are called with the mutex already held. Calling `lock()` inside them is unnecessary (though the mutex is recursive, it won't deadlock).

6. **asyn: `interfaceMask` must include every interface used.** Missing `asynFloat64Mask` → `asynParamFloat64` parameters are inaccessible. Match `interruptMask` to `interfaceMask` for I/O Intr.

7. **DTYP must match the device support or asyn interface type.** Mismatched DTYP silently produces zero values. EPICS does not warn about this at record load time.

8. **FTVL must match the array element type.** `"DOUBLE"` ↔ `asynFloat64ArrayIn/Out`, `"FLOAT"` ↔ `asynFloat32ArrayIn/Out`, `"LONG"` ↔ `asynInt32ArrayIn/Out`, `"CHAR"` ↔ `asynInt8ArrayIn/Out`.

9. **`PINI = "YES"` on output records.** Ensures the initial setpoint reaches the driver at `iocInit`. Without it, outputs hold defaults until an operator writes.

10. **`_RBV` suffix is convention, not enforced.** Use it consistently to distinguish setpoint records from actual hardware state readbacks.
