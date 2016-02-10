<?php

    // file_put_contents("/tmp/checkuser", "test");
    // $user = fileowner("/tmp/checkuser");
    // unlink("/tmp/checkuser");
    // if ($user!=1000) die;
    
    # get passed emoncms location from bash e.g. $ echo /var/www/emoncms | php get_emoncms_mysql_auth.php
    function getInput()
    {
        $input = '';
        $fr = fopen("php://stdin", "r");
        while (!feof ($fr))
        {
            $input .= fgets($fr);
        }
    fclose($fr);
    return $input;
    }

    $emoncms_dir = getInput();
    
    # Strip new line
    $emoncms_dir = trim(preg_replace('/\s\s+/', ' ', $emoncms_dir));
    
    # Get MYSQL auth details from Emoncms settings.php
    chdir($emoncms_dir);
    //chdir("/var/www/emoncms");
    define('EMONCMS_EXEC', 1);
    require "process_settings.php";
    echo $username.":".$password;
