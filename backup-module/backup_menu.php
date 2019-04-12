<?php
    $domain = "messages";
    bindtextdomain($domain, "Modules/admin/locale");
    bind_textdomain_codeset($domain, 'UTF-8');
    
    $menu_left[] = array(
        'id'=>"backup_menu",
        'name'=>dgettext($domain, "Backup"), 
        'path'=>"backup" , 
        'session'=>"write", 
        'order' => 0,
        'icon'=>'icon-circle-arrow-down icon-white',
        'hideinactive'=>1
    );

    $menu_dropdown_config[] = array(
        'id'=>"backup_menu_extras",
        'name'=>dgettext($domain, "Backup"), 
        'path'=>"backup" , 
        'session'=>"write", 
        'order' => 55,
        'icon'=>'icon-circle-arrow-down'
    );
    
    

