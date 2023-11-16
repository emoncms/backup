# Emoncms backup export and import tool for backup and migration

* Export a compressed archive containing Emoncms Inputs, Feed data, Dashboards & config

* Backup contains the Emoncms MYSQL database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf

* Import compressed archive into another Emoncms account

## User Guide

[Backup module User Guide](https://guide.openenergymonitor.org/setup/import/)

Via Emoncms module web interface [(see video screencast guide)](https://www.youtube.com/watch?v=5U_tOlsWjXM) or manual (see below for manual instructions):

## Install

**Requirements**

- Latest emoncms master or stable branch, installed in /var/www/emoncms
- Emoncms with redis enabled
- Emoncms with service-runner service running (see: [Emoncms: Install Service-runner](https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md))

If you have not done so already, install the EmonScripts repository:

    cd /opt/openenergymonitor
    git clone https://github.com/openenergymonitor/EmonScripts.git
 
Install this module in /opt/emoncms/modules:

    cd /opt/emoncms/modules
    git clone https://github.com/emoncms/backup.git
    
Run backup module installation script to modify php.ini and setup uploads folder:

    cd backup
    ./install.sh

## Manual Export Instructions

Run `./emoncms-export.sh`

## Manual Import Instructions

If importing large backup files browser upload method may fail. In this case follow:

1. Copy `emoncms-backup-xxx.tar.gz` backup file to `data_source_path` in `config.cfg`
2. Run `./emoncms-import.sh`


