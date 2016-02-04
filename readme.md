# Emoncms backup export and import tool for backup and migration

### service-runner

The backup utility first requires service-runner to be running in the background or the emonpi/emonbase or other server that emoncms is running on. service-runner provides a way of starting background scripts from the emoncms UI so that when the 'create backup' button is clicked in the browser this first created a flag in /tmp of the form /tmp/emoncms-flag-export. This flag file contains the location of the script to be ran by the service-runner and the location of a log file to be written too. service-runner checks for flags every 1 seconds and runs the script as described in the flag file.

To install service-runner add the following entry to crontab (crontab -e):

    * * * * * /var/www/emoncms/Modules/backup/service-runner >> /var/log/service-runner.log 2>&1
    
    

    

