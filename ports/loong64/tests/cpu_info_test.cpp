// Probe for Stacer's hardware-information layer on a given machine.
// Links against the upstream stacer-core static library (no GUI needed).
// Output: a single JSON object on stdout, suitable for before/after diffing.
//
// Build: see tests/run.sh
#include "Info/cpu_info.h"
#include "Info/system_info.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>
#include <QDebug>

static QJsonArray toJson(const QList<double> &values)
{
    QJsonArray a;
    for (double v : values)
        a.append(v);
    return a;
}

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);

    CpuInfo ci;
    SystemInfo si;

    QJsonObject o;
    o["physicalCoreCount"] = ci.getCpuPhysicalCoreCount();
    o["logicalCoreCount"] = ci.getCpuCoreCount();
    o["avgClockMHz"] = ci.getAvgClock();
    o["clocksMHz"] = toJson(ci.getClocks());
    o["clockCount"] = ci.getClocks().size();

    QJsonArray percents;
    const QList<int> cpuPercents = ci.getCpuPercents();
    for (int v : cpuPercents)
        percents.append(v);
    o["cpuPercents"] = percents;

    o["sysCpuModel"] = si.getCpuModel();
    o["sysCpuSpeed"] = si.getCpuSpeed();
    o["sysCpuCore"] = si.getCpuCore();
    o["sysPlatform"] = si.getPlatform();
    o["sysDistribution"] = si.getDistribution();
    o["sysKernel"] = si.getKernel();

    QTextStream out(stdout);
    out << QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Indented));
    return 0;
}
