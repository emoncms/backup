#!/bin/bash
echo "Backup module installation script"

usrdir=$1
if [ "$usrdir" = "" ]; then
    echo "usrdir argument missing"
    exit 0
fi
upload_dir=$usrdir/data/uploads

# Symlink emoncms UI (if not done so already)
# emoncms_www=/var/www/emoncms
# if [ ! -L $emoncms_www/Modules/backup ]; then
#     ln -s $usrdir/modules/backup/backup-module $emoncms_www/Modules/backup
# fi

# php_ini=/etc/php5/apache2/php.ini
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d"." )
php_ini=/etc/php/$PHP_VER/apache2/php.ini

# Modify php.ini
# echo "- applying php.ini modifications"
# sudo sed -i "s/^post_max_size.*/post_max_size = 3G/" $php_ini
# sudo sed -i "s/^upload_max_filesize.*/upload_max_filesize = 3G/" $php_ini
# sudo sed -i "s~^;upload_tmp_dir.*~upload_tmp_dir = $upload_dir~" $php_ini
# sudo sed -i "s~^upload_tmp_dir.*~upload_tmp_dir = $upload_dir~" $php_ini

cat << EOF |
post_max_size = 3G
upload_max_filesize = 3G
upload_tmp_dir = ${upload_dir}
upload_tmp_dir = ${upload_dir}
EOF
sudo tee /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini

sudo phpenmod emoncmsbackup

# Create uploads folder
if [ ! -d $usrdir/data ]; then
    echo "- creating $usrdir/data directory"
    mkdir $usrdir/data
fi

if [ ! -d $usrdir/data/uploads ]; then
    echo "- creating $usrdir/data/uploads directory"
    mkdir $usrdir/data/uploads
    sudo chown www-data $usrdir/data/uploads -R
fi

echo "- restarting apache"
sudo service apache2 restart
