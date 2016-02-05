<?php

    // file_put_contents("/tmp/checkuser", "test");
    // $user = fileowner("/tmp/checkuser");
    // unlink("/tmp/checkuser");
    // if ($user!=1000) die;

    chdir("/var/www/emoncms");
    define('EMONCMS_EXEC', 1);
    require "process_settings.php";
    echo $username.":".$password;
