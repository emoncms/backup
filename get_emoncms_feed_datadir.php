<?php
chdir("/var/www/emoncms");
define('EMONCMS_EXEC', 1);
require "process_settings.php";

foreach ($feed_settings as $engine=>$entry) {
if (isset($feed_settings[$engine]) && isset($feed_settings[$engine]["datadir"]))
    echo $engine.'_location="'.$feed_settings[$engine]["datadir"].'"'."\n\n";
}

