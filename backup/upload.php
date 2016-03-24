<?php



function bytesToSize1024($bytes, $precision = 2) {
    $unit = array('B','KB','MB');
    return @round($bytes / pow(1024, ($i = floor(log($bytes, 1024)))), $precision).' '.$unit[$i];
}

$sFileName = $_FILES['upload_file']['name'];
$sFileType = $_FILES['upload_file']['type'];
$sFileSize = bytesToSize1024($_FILES['upload_file']['size'], 1);

$uploads_dir = '/home/pi/data/uploads';

if (is_uploaded_file($_FILES['upload_file']['tmp_name'])) {
   echo "<p>File: ". $sFileName." uploaded successfully</p>";
   echo "<p>Size: ". $sFileType."</p>";
   echo "<p>Type: ". $sFileSize."</p>";
   move_uploaded_file($_FILES['upload_file']['tmp_name']  , "$uploads_dir/$sFileName");
} else {
   echo "Error: file". $sFileName." not uploaded";
}
