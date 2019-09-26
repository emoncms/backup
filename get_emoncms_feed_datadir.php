<?php
chdir("/var/www/emoncms");
define('EMONCMS_EXEC', 1);
require "process_settings.php";

foreach ($settings['feed'] as $engine=>$entry) {
if (isset($settings['feed'][$engine]) && isset($settings['feed'][$engine]["datadir"]))
    echo $engine.'_location="'.$settings['feed'][$engine]["datadir"].'"'."\n\n";
}

