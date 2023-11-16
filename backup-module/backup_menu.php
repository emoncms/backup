<?php
global $session;
if ($session["write"]) $menu["setup"]["l2"]['backup'] = array("name"=>"Backup","href"=>"backup", "order"=>9, "icon"=>"box-add");
