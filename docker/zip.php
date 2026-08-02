<?php
/**
 * Package a directory into a Joomla-installable zip.
 *
 * ponytail: PHP's ZipArchive rather than the host's `zip` — Joomla requires the
 * zip extension, so it is guaranteed present inside this image, and it behaves
 * identically whether the developer is on Linux, macOS or Windows.
 *
 * Usage: php zip.php <source-dir> <output.zip>
 */

$src = $argv[1] ?? null;
$out = $argv[2] ?? null;

if (!$src || !$out) {
    fwrite(STDERR, "usage: zip.php <source-dir> <output.zip>\n");
    exit(1);
}

$base = realpath($src);

if ($base === false || !is_dir($base)) {
    fwrite(STDERR, "not a directory: $src\n");
    exit(1);
}

@unlink($out);

$zip = new ZipArchive();

if ($zip->open($out, ZipArchive::CREATE) !== true) {
    fwrite(STDERR, "cannot create: $out\n");
    exit(1);
}

$files = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS)
);

$count = 0;

// Editor and Finder droppings would otherwise ship inside `make package` zips.
$junk = ['.DS_Store', 'Thumbs.db', 'desktop.ini'];

foreach ($files as $file) {
    if ($file->isFile() && !in_array($file->getFilename(), $junk, true)) {
        $zip->addFile($file->getPathname(), substr($file->getPathname(), strlen($base) + 1));
        $count++;
    }
}

$zip->close();

if ($count === 0) {
    fwrite(STDERR, "no files found in $src\n");
    exit(1);
}

printf("packaged %d files -> %s\n", $count, $out);
