<?php
    $domain = "messages";
    bindtextdomain($domain, "Modules/admin/locale");
    bind_textdomain_codeset($domain, 'UTF-8');
    $menu_dropdown_config[] = array('name'=> dgettext($domain, "Backup"), 'icon'=>'icon-circle-arrow-down', 'path'=>"backup" , 'session'=>"write", 'order' => 55 );
