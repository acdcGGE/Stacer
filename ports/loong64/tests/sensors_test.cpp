#include <QDebug>

#include "Info/sensor_info.h"

int main()
{
    SensorInfo s;

    qDebug() << "CPU temp (C):" << s.getCpuTemp();
    qDebug() << "GPU temp (C):" << s.getGpuTemp();
    qDebug() << "GPU usage (%):" << s.getGpuUsage();
    qDebug() << "GPU clock (MHz):" << s.getGpuClock();

    QList<TempReading> disks = s.getDiskTemperatures();
    qDebug() << "Disk temps:" << disks.size();
    for (const TempReading &d : disks)
        qDebug() << "   " << d.label << "->" << d.temp << "C (" << d.source << ")";

    QList<TempReading> all = s.getHwmonTemperatures();
    qDebug() << "All hwmon sensors:" << all.size();
    for (const TempReading &r : all)
        qDebug() << "   [" << r.type << "]" << r.label
                 << "->" << r.temp << "C (" << r.source << ")";

    return 0;
}
