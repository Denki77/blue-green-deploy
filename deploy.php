<?php

declare(strict_types=1);

function parse_kv_file(string $path): array {
    $out = [];
    $lines = @file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($lines === false) return $out;

    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#' || $line[0] === ';') continue;
        $pos = strpos($line, '=');
        if ($pos === false) continue;

        $k = trim(substr($line, 0, $pos));
        $v = trim(substr($line, $pos + 1));

        // strip optional quotes
        $v = preg_replace('/^"(.*)"$/', '$1', $v);
        $v = preg_replace("/^'(.*)'$/", '$1', $v);

        $out[$k] = $v;
    }
    return $out;
}

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'POST') {
    http_response_code(405);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Use POST\n";
    exit;
}

// --- locate config relative to this file ---
$sharedDir = dirname(__DIR__);                 // .../deploy/shared
$configPath = $sharedDir . '/.deploy-webhook'; // .../deploy/shared/.deploy-webhook

if (!is_file($configPath)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Config not found.\n";
    exit;
}

$cfg = parse_kv_file($configPath);

$token = $cfg['DEPLOY_TOKEN'] ?? '';
$baseDir = $cfg['BASE_DIR'] ?? '';

if ($token === '' || $baseDir === '') {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Config missing DEPLOY_TOKEN or BASE_DIR\n";
    exit;
}

$hdr = $_SERVER['HTTP_X_DEPLOY_TOKEN'] ?? '';
if (!hash_equals($token, $hdr)) {
    http_response_code(403);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Forbidden\n";
    exit;
}

// simple rate limit: at most 1 request per 10 seconds
$rateFile = $sharedDir . '/.deploy-rate';
$now = time();
$last = 0;
if (is_file($rateFile)) {
    $last = (int)trim((string)@file_get_contents($rateFile));
}
if ($last > 0 && ($now - $last) < 10) {
    http_response_code(429);
    header('Content-Type: text/plain; charset=utf-8');
    echo "Too Many Requests\n";
    exit;
}
@file_put_contents($rateFile, (string)$now, LOCK_EX);

$script = rtrim($baseDir, '/') . '/deploy.sh';
$log = rtrim($baseDir, '/') . '/shared/deploy.log';

if (!is_file($script)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "deploy.sh not found\n";
    exit;
}

$home = dirname($baseDir);

$cmd = sprintf(
    'HOME=%s BASE_DIR=%s nohup /bin/bash -lc %s >> %s 2>&1 & echo OK',
    escapeshellarg($home),
    escapeshellarg($baseDir),
    escapeshellarg($script),
    escapeshellarg($log)
);

header('Content-Type: text/plain; charset=utf-8');
echo shell_exec($cmd) ?: "OK\n";
