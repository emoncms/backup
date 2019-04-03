## Emoncms backup export and import tool for backup and migration

* Export a compressed archive containing Emoncms Inputs, Feed data, Dashboards & config

* Backup contains the Emoncms MYSQL database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf

* Import compressed archive into another Emoncms account

### [Backup module User Guide](https://guide.openenergymonitor.org/setup/import/)

Via Emoncms module web interface [(see video screencast guide)](https://www.youtube.com/watch?v=5U_tOlsWjXM) or manual (see below for manual instructions):

---

### Install

**Requirements**

- Latest emoncms master or stable branch
- Emoncms with redis enabled
- Emoncms with service-runner service running
 
Install this module within your emoncms usr folder:

    cd /usr/emon/emoncms_modules
    git clone https://github.com/emoncms/backup.git
    
Symlink the sub-folder called backup-module to your emoncms Modules directory:

    cd backup
    ln -s $PWD/backup-module /var/www/emoncms/Modules/backup
    
Run backup module installation script to modify php.ini and setup uploads folder<br>(Set $usrdir to your usr directory above e.g /usr/emon):

    ./install.sh $usrdir

### Configure

Make a copy of `default.config.cfg` called `config.cfg`. Set the paths in `config.cfg` to match your system.

---

### Manual Export Instructions

1. Configure paths in `config.cfg` to match your system
2. Run `./emoncms-export.sh`

### Manual Import Instructions

If importing large backup files browser upload method may fail. In this case follow:

1. Configure paths in `config.cfg` to match your system
2. Copy `emoncms-backup-xxx.tar.gz` backup file to `$usrdir/data/uploads` or whatever you have set as `data_source_path` in `config.cfg` to be
3. Run `./emoncms-import.sh`


