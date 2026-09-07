<?php
    /*
     All Emoncms code is released under the GNU Affero General Public License.
     See COPYRIGHT.txt and LICENSE.txt.

        ---------------------------------------------------------------------
        Emoncms - open source energy visualisation
        Part of the OpenEnergyMonitor project:
        http://openenergymonitor.org
    */

    // no direct access
    defined('EMONCMS_EXEC') or die('Restricted access');

// Ask drive-backup.sh which mounted drives could hold a backup.
//
// Discovery is read only and needs no privileges, so it can run as the web user.
// Keeping it in the script rather than reimplementing it here means the list the
// interface offers and the list --set-path accepts can never disagree.
function backup_discover_drives($parsed_ini)
{
    $script = "";
    if (isset($parsed_ini['backup_script_location'])) {
        $script = $parsed_ini['backup_script_location']."/drive-backup.sh";
    }
    if (!is_file($script)) $script = "/opt/emoncms/modules/backup/drive-backup.sh";
    if (!is_file($script)) return array();

    $lines = array();
    @exec(escapeshellarg($script)." --discover 2>/dev/null", $lines);

    $drives = array();
    foreach ($lines as $line) {
        $f = explode("\t", $line);
        if (count($f) < 6) continue;
        $drives[] = array(
            "mountpoint"  => $f[0],
            "source"      => $f[1],
            "fstype"      => $f[2],
            "kind"        => $f[3],
            "free_mb"     => (int) $f[4],
            "initialised" => ($f[5] === "yes"),
            // What the destination filesystem adds on top of the incremental
            // sync, see discover_destinations() in drive-backup.sh
            "compressed"  => (isset($f[6]) && $f[6] === "yes"),
            "snapshots"   => (isset($f[7]) && $f[7] === "yes")
        );
    }
    return $drives;
}

// Ask drive-backup.sh which attached drives are not mounted yet.
//
// The counterpart to backup_discover_drives(): that one lists filesystems that
// are already mounted, this one lists drives that are plugged in and doing
// nothing, which is what a user sees after plugging in a new USB drive. Also
// read only, and the same script decides what --mount will accept.
function backup_discover_devices($parsed_ini)
{
    $script = "";
    if (isset($parsed_ini['backup_script_location'])) {
        $script = $parsed_ini['backup_script_location']."/drive-backup.sh";
    }
    if (!is_file($script)) $script = "/opt/emoncms/modules/backup/drive-backup.sh";
    if (!is_file($script)) return array();

    $lines = array();
    @exec(escapeshellarg($script)." --discover-devices 2>/dev/null", $lines);

    $devices = array();
    foreach ($lines as $line) {
        $f = explode("\t", $line);
        if (count($f) < 8) continue;
        $devices[] = array(
            // Identifier used to name this drive back to --mount. A
            // /dev/disk/by-id path where the drive has one, so that it still
            // refers to the same physical drive if the kernel names change
            // between the scan and the user confirming.
            "id"      => $f[0],
            "device"  => $f[1],
            "size_mb" => (int) $f[2],
            "fstype"  => $f[3],
            "label"   => $f[4],
            "model"   => $f[5],
            "kind"    => $f[6],
            // available | infstab | nofilesystem, see discover_devices()
            "state"   => $f[7],
            // The whole disk this device sits on, which is what formatting
            // erases, and a description of everything currently on it
            "disk"          => isset($f[8]) ? $f[8] : $f[1],
            "disk_size_mb"  => isset($f[9]) ? (int) $f[9] : (int) $f[2],
            "disk_contents" => isset($f[10]) ? $f[10] : ""
        );
    }
    return $devices;
}

// Which discovered drive holds the configured backup path. Matched by longest
// mountpoint prefix so a path set by hand in config.cfg still resolves to the
// filesystem it actually lives on.
function backup_drive_for_path($parsed_ini, $backup_path)
{
    $best = false;
    $best_len = -1;
    foreach (backup_discover_drives($parsed_ini) as $drive) {
        $mp = rtrim($drive['mountpoint'], '/');
        if ($mp === "") continue;
        if ($backup_path === $mp || strpos($backup_path, $mp.'/') === 0) {
            if (strlen($mp) > $best_len) { $best = $drive; $best_len = strlen($mp); }
        }
    }
    return $best;
}

// When the daily timer will next run, so the interface can say whether the
// backup is actually scheduled rather than only reporting the last run.
function backup_next_scheduled()
{
    $out = array();
    @exec("systemctl show emoncms-drive-backup.timer --property=NextElapseUSecRealtime,ActiveState 2>/dev/null", $out);

    // null rather than false when systemd cannot be asked at all, in a container
    // say. Only an answer of "the timer exists and is inactive" should be
    // reported to the user as backups not being scheduled.
    $next = false; $active = null;
    foreach ($out as $line) {
        if (strpos($line, "NextElapseUSecRealtime=") === 0) {
            $v = trim(substr($line, strlen("NextElapseUSecRealtime=")));
            if ($v !== "" && $v !== "n/a" && ctype_digit($v) && $v > 0) $next = (int) ($v / 1000000);
        }
        if (strpos($line, "ActiveState=") === 0) {
            $active = (trim(substr($line, strlen("ActiveState="))) === "active");
        }
    }
    return array("scheduled" => $active, "next_run" => $next);
}

function backup_controller()
{
    global $route, $session, $path, $redis, $linked_modules_dir, $settings;
    $result = false;
    // This module is only to be ran by the admin user
    if (!isset($session['admin']) || !$session['admin']) {
        $route->format = "html";
        return "<br><div class='alert alert-error'><b>".tr("Error:")."</b> ".tr("backup module requires admin access")."</div>";
    }
    if (file_exists("$linked_modules_dir/backup/config.cfg")) {
        $ini_string = file_get_contents("$linked_modules_dir/backup/config.cfg");
        // Strip out comments from ini file
        $ini_string_lines = explode("\n",$ini_string);
        $tmp = array();
        for ($i=0; $i<count($ini_string_lines); $i++) {
            if (isset($ini_string_lines[$i][0]) && $ini_string_lines[$i][0]!="#") $tmp[] = $ini_string_lines[$i];
        }
        $ini_string_lines = $tmp;
    
        $parsed_ini = parse_ini_string(implode("\n",$ini_string_lines), true);

        // A destination chosen in this interface is kept in its own file rather
        // than in config.cfg, and takes precedence over it. Same precedence and
        // same strict pattern as drive-backup.sh, so both sides agree on where
        // the backup lives.
        $path_conf = "$linked_modules_dir/backup/drive-backup-path.conf";
        if (file_exists($path_conf)) {
            foreach (file($path_conf) as $line) {
                if (strpos($line, "drive_backup_path=") === 0) {
                    $ui_path = trim(substr($line, strlen("drive_backup_path=")));
                    if (preg_match('/^\/[A-Za-z0-9._@\/+-]+$/', $ui_path)) {
                        $parsed_ini['drive_backup_path'] = $ui_path;
                    }
                    break;
                }
            }
        }
    } else {
        return "<br><div class='alert alert-error'><b>".tr("Error:")."</b> ".tr("missing backup config.cfg")."</div>";
    }
    
    $export_logfile = $settings['log']['location']."/exportbackup.log";
    $import_logfile = $settings['log']['location']."/importbackup.log";
    $usb_import_logfile = $settings['log']['location']."/usbimport.log";
    $drive_backup_logfile = $settings['log']['location']."/drivebackup.log";
    $drive_backup_verify_logfile = $settings['log']['location']."/drivebackup-verify.log";
    $drive_restore_logfile = $settings['log']['location']."/driverestore.log";

    if ($route->format == 'html' && $route->action == "") {
        $result = view("Modules/backup/backup_view.php",array("parsed_ini"=>$parsed_ini));
    }

    if ($route->action == 'start') {
        $route->format = "text";
        $redis->rpush("service-runner", json_encode(["run" => "backup-export", "args" => [], "log" => "exportbackup"]));
    }

    if ($route->action == 'exportlog') {
        $route->format = "text";
        if (file_exists($export_logfile)) {
            $result = trim(file_get_contents($export_logfile));
        } else {
            $result = "";
        }
    }

    if ($route->action == 'importlog') {
        $route->format = "text";
        if (file_exists($import_logfile)) {
            $result = trim(file_get_contents($import_logfile));
        } else {
            $result = "";
        }
    }

    if ($route->action == 'usbimportlog') {
        $route->format = "text";
        if (file_exists($usb_import_logfile)) {
            $result = trim(file_get_contents($usb_import_logfile));
        } else {
            $result = "";
        }
    }
    
    if ($route->action == "download") {
        header("Content-type: application/zip");
        $backup_filename="emoncms-backup-".preg_replace('/[^a-zA-Z0-9\-]/', '-', gethostname())."-".date("Y-m-d").".tar.gz";
        header("Content-Disposition: attachment; filename=\"$backup_filename\"");
        header("Pragma: no-cache");
        header("Expires: 0");
        readfile($parsed_ini['backup_location']."/".$backup_filename);
        exit;
    }

    if ($route->action == "upload") {
        // These need to be set in php.ini
        // ini_set('upload_max_filesize', '200M');
        // ini_set('post_max_size', '200M');
        $uploadOk = 1;
        $target_path = $parsed_ini['backup_location']."/uploads/";
        $target_path = $target_path . basename( $_FILES['file']['name']);
        
        $imageFileType = pathinfo($target_path,PATHINFO_EXTENSION);
        
        // Allow certain file formats
        if($imageFileType != "gz")
        {
            $result = tr("Sorry, only .tar.gz files are allowed.");
            $uploadOk = 0;
        }

        if ((move_uploaded_file($_FILES['file']['tmp_name'], $target_path)) && ($uploadOk == 1)) {

            $redis->rpush("service-runner", json_encode(["run" => "backup-import", "args" => [], "log" => "importbackup"]));
            header('Location: '.$path.'backup#restore');
        } else {
            return "<br><div class='alert alert-error'><b>".tr("Error:")."</b> ".tr("Import archive not selected")."</div>";
        }
    }
    
    if ($route->action == "usbimport") {
        $route->format = "text";
        $result = tr("Starting USB import");
        $redis->rpush("service-runner", json_encode(["run" => "backup-usb-import", "args" => [], "log" => "usbimport"]));
    }

    // ------------------------------------------------------------------
    // Write efficient backup to an attached drive (drive-backup.sh)
    // ------------------------------------------------------------------

    if ($route->action == "drivebackup") {
        $route->format = "text";
        $result = tr("Starting drive backup");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-sync", "args" => [], "log" => "drivebackup"]));
    }

    if ($route->action == "drivebackupverify") {
        $route->format = "text";
        $result = tr("Starting backup drive verify");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-verify", "args" => ["--verify"], "log" => "drivebackupverify"]));
    }

    if ($route->action == 'drivebackuplog') {
        $route->format = "text";
        if (file_exists($drive_backup_logfile)) {
            $result = trim(file_get_contents($drive_backup_logfile));
        } else {
            $result = "";
        }
    }

    if ($route->action == 'drivebackupverifylog') {
        $route->format = "text";
        if (file_exists($drive_backup_verify_logfile)) {
            $result = trim(file_get_contents($drive_backup_verify_logfile));
        } else {
            $result = "";
        }
    }

    // Drives that could hold a backup. drive-backup.sh --discover is the single
    // authority on this list: it is read only and needs no privileges, and the
    // same function decides what --set-path will accept, so the interface can
    // never offer a destination the script would then refuse.
    if ($route->action == 'drivediscover') {
        $route->format = "json";
        $result = backup_discover_drives($parsed_ini);
    }

    // Select one of those drives as the backup destination. The value is checked
    // here and then checked again by drive-backup.sh against its own discovery,
    // which is what stops this being a way to point a root process anywhere.
    if ($route->action == 'drivesetpath') {
        $route->format = "text";

        $mountpoint = isset($_GET['mountpoint']) ? $_GET['mountpoint'] : "";
        $found = false;
        foreach (backup_discover_drives($parsed_ini) as $drive) {
            if ($drive['mountpoint'] === $mountpoint) $found = true;
        }
        if (!$found) {
            return array('content' => tr("That drive is not available for backup"));
        }

        $result = tr("Preparing backup drive");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-setpath", "args" => ["--set-path", $mountpoint], "log" => "drivebackup"]));
    }

    // Drives that are plugged in but not mounted, so the interface can offer to
    // set one up rather than telling the user to go and edit /etc/fstab.
    if ($route->action == 'drivedevices') {
        $route->format = "json";
        $result = backup_discover_devices($parsed_ini);
    }

    // Mount one of those drives, add it to /etc/fstab and use it for backups.
    // As with drivesetpath, the identifier is checked here and then checked
    // again by drive-backup.sh against its own discovery before it mounts
    // anything, so this cannot be used to mount a device of the caller's
    // choosing.
    if ($route->action == 'drivemount') {
        $route->format = "text";

        $id = isset($_GET['id']) ? $_GET['id'] : "";
        $found = false;
        foreach (backup_discover_devices($parsed_ini) as $device) {
            // A drive with no filesystem has nothing to mount. It needs
            // driveformatmount, which asks the user a much bigger question.
            if ($device['id'] === $id && $device['state'] !== "nofilesystem" && $device['state'] !== "nomedia") $found = true;
        }
        if (!$found) {
            return array('content' => tr("That drive is not available to set up"));
        }

        $result = tr("Setting up drive");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-mount", "args" => ["--mount", $id], "log" => "drivebackup"]));
    }

    // The same, but formatting the drive as btrfs first. This erases the whole
    // disk the drive is on, so it is a separate action and the browser has to
    // send the confirmation word as well. Any drive in the scan may be chosen:
    // the scan never lists anything on a disk the system is using.
    if ($route->action == 'driveformatmount') {
        $route->format = "text";

        $id = isset($_GET['id']) ? $_GET['id'] : "";
        $confirm = isset($_GET['confirm']) ? $_GET['confirm'] : "";
        if ($confirm !== "ERASE") {
            return array('content' => tr("Formatting was not confirmed"));
        }

        $found = false;
        foreach (backup_discover_devices($parsed_ini) as $device) {
            if ($device['id'] === $id && $device['state'] !== "nomedia") $found = true;
        }
        if (!$found) {
            return array('content' => tr("That drive is not available to format"));
        }

        $result = tr("Formatting and setting up drive");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-mount", "args" => ["--format-mount", $id, "--confirm-erase"], "log" => "drivebackup"]));
    }

    // Turn the daily backup and weekly verify timers on or off. The interface
    // reports whether backups are scheduled, so it has to be able to change it.
    if ($route->action == 'driveschedule') {
        $route->format = "text";

        $enable = isset($_GET['enable']) && $_GET['enable'] == "1";
        $arg = $enable ? "--enable-schedule" : "--disable-schedule";

        $result = $enable ? tr("Turning on daily backup") : tr("Turning off daily backup");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-schedule", "args" => [$arg], "log" => "drivebackup"]));
    }

    if ($route->action == 'driverestorelog') {
        $route->format = "text";
        if (file_exists($drive_restore_logfile)) {
            $result = trim(file_get_contents($drive_restore_logfile));
        } else {
            $result = "";
        }
    }

    // Restore overwrites the live database and feed data. The snapshot name
    // arrives from the browser, so it is only accepted if it is a bare filename
    // that is actually one of the snapshots present on the backup drive.
    if ($route->action == "driverestore") {
        $route->format = "text";

        $drive_backup_path = isset($parsed_ini['drive_backup_path']) ? $parsed_ini['drive_backup_path'] : "";
        if ($drive_backup_path == "" || !file_exists("$drive_backup_path/.emoncms-backup-target")) {
            return array('content' => tr("Backup drive not available"));
        }

        $args = array("--yes");
        if (isset($_GET['delete']) && $_GET['delete'] == "1") {
            $args[] = "--delete";
        }

        $sql = isset($_GET['sql']) ? $_GET['sql'] : "";

        if ($sql != "") {
            if ($sql !== basename($sql)) {
                return array('content' => tr("Invalid snapshot name"));
            }
            $found = false;
            foreach (array("daily","weekly") as $period) {
                if (file_exists("$drive_backup_path/sql/$period/$sql")) $found = true;
            }
            if (!$found) {
                return array('content' => tr("Snapshot not found on the backup drive"));
            }
            $args[] = "--sql";
            $args[] = $sql;
        }

        $result = tr("Starting drive restore");
        $redis->rpush("service-runner", json_encode(["run" => "backup-drive-restore", "args" => $args, "log" => "driverestore"]));
    }

    // Result of the last run, read from status.json on the backup drive itself,
    // so an unplugged drive is reported as unavailable rather than showing stale
    // figures from a previous run
    if ($route->action == 'drivebackupstatus') {
        $route->format = "json";

        $drive_backup_path = isset($parsed_ini['drive_backup_path']) ? $parsed_ini['drive_backup_path'] : "";
        $status = array(
            "configured" => ($drive_backup_path != ""),
            "path" => $drive_backup_path,
            "available" => false,
            // Mounted and looking correct, but not answering. Distinct from
            // absent, because the fix is to remount rather than to reconnect.
            "unresponsive" => false,
            "status" => false,
            "free_mb" => 0,
            "total_mb" => 0,
            "sql" => array()
        );

        // The marker file is what drive-backup.sh itself checks for, so this
        // reports availability on exactly the same basis as the script
        if ($status['configured'] && file_exists("$drive_backup_path/.emoncms-backup-target")) {

            // A drive that was unplugged and plugged back in leaves the old mount
            // in place, answering every access with an I/O error. file_exists()
            // above can still be satisfied from the kernel's directory cache, so
            // ask the filesystem something it cannot answer from cache before
            // trusting any of this.
            $free = @disk_free_space($drive_backup_path);
            $total = @disk_total_space($drive_backup_path);
            $marker_readable = (@file_get_contents("$drive_backup_path/.emoncms-backup-target") !== false);

            if ($free === false || $total === false || !$marker_readable) {
                $status['unresponsive'] = true;
            } else {
                $status['available'] = true;
                $status['free_mb'] = round($free / 1048576);
                $status['total_mb'] = round($total / 1048576);

                if (file_exists("$drive_backup_path/status.json")) {
                    $decoded = json_decode(file_get_contents("$drive_backup_path/status.json"), true);
                    if ($decoded !== null) $status['status'] = $decoded;
                }

                foreach (array("daily","weekly") as $period) {
                    $files = @glob("$drive_backup_path/sql/$period/*.sql.gz");
                    if ($files === false) $files = array();
                    rsort($files);
                    foreach ($files as $file) {
                        $status['sql'][] = array(
                            "period" => $period,
                            "name" => basename($file),
                            "size_mb" => round(filesize($file) / 1048576, 1)
                        );
                    }
                }
            }
        }

        $status['schedule'] = backup_next_scheduled();
        if ($status['available']) {
            $drive = backup_drive_for_path($parsed_ini, $drive_backup_path);
            if ($drive !== false) $status['drive'] = $drive;
        }

        $result = $status;
    }

    return array('content'=>$result);
}
