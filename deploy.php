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

$home = $_SERVER['HOME'] ?? '';
// We prefer BASE_DIR from config, but need an initial guess to locate config.
// Common default:
$baseGuess = ($home !== '') ? ($home . '/deploy') : '';
$configPath = $baseGuess . '/shared/.deploy-webhook';

$cfg = parse_kv_file($configPath);

// If config specifies BASE_DIR elsewhere, reload from that location (optional robustness)
if (isset($cfg['BASE_DIR']) && $cfg['BASE_DIR'] !== '' && $cfg['BASE_DIR'] !== $baseGuess) {
    $configPath = rtrim($cfg['BASE_DIR'], '/') . '/shared/.deploy-webhook';
    $cfg = parse_kv_file($configPath);
}

$token = $cfg['DEPLOY_TOKEN'] ?? '';
$baseDir = $cfg['BASE_DIR'] ?? $baseGuess;

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

$script = rtrim($baseDir, '/') . '/deploy.sh';
$log = rtrim($baseDir, '/') . '/shared/deploy.log';

if (!is_file($script)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    echo "deploy.sh not found\n";
    exit;
}

$cmd = sprintf(
    'HOME=%s BASE_DIR=%s nohup /bin/bash -lc %s >> %s 2>&1 & echo OK',
    escapeshellarg($home),
    escapeshellarg($baseDir),
    escapeshellarg($script),
    escapeshellarg($log)
);

header('Content-Type: text/plain; charset=utf-8');
echo shell_exec($cmd) ?: "OK\n";
