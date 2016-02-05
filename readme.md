# Emoncms backup export and import tool for backup and migration

Install this module in your home folder then symlink the sub-folder called backup to your emoncms Modules directory:

    cd /home/pi
    git clone https://github.com/emoncms/backup.git
    ln -s /home/pi/backup/backup /var/www/emoncms/Modules/backup    

### service-runner

The backup utility first requires service-runner to be running in the background on the emonpi/emonbase or other server that emoncms is running on. service-runner provides a way of starting background scripts from the emoncms UI so that when the 'create backup' button is clicked in the browser this first creates a flag in /tmp of the form /tmp/emoncms-flag-name. This flag file contains the location of the script to run and a log file. service-runner checks for flags every 1 seconds.

To install service-runner add the following entry to crontab (crontab -e):

    * * * * * /var/www/emoncms/Modules/backup/service-runner >> /var/log/service-runner.log 2>&1
    
# php.ini

In order to enable uploads of backup zip files we need to set the maximum upload size to be larger than the file we want to upload. This can be set system wide in /etc/php5/apache2/php.ini:

    sudo nano /etc/php5/apache2/php.ini
    
Set:

    post_max_size = 200M
    upload_max_filesize = 200M

# Create uploads folder

    sudo mkdir /home/pi/data/uploads
    sudo chown www-data /home/pi/data/uploads
