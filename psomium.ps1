# Invoke-ps2exe -noConsole -nooutput -copyright "Stephan Cieszynski" -product Psomium -version 0.0.0.1 -iconFile .\favicon.ico -inputFile .\psomium.ps1

$html = @"
<!DOCTYPE html>
<html lang="de">

<head>
    <title>psomium</title>
    <meta charset="utf-8">
    <script>
Object.defineProperty(globalThis, 'psomium', {
    value: globalThis?.psomium ?? new class psomium {

        constructor() {

            const url = new URL(location);
            url.protocol = 'ws';

            const websocket = new WebSocket(url);

            websocket.onopen = (event) => {
                console.debug('websocket.onopen');
            }

            websocket.onclose = (event) => {
                console.debug('websocket.onclose');
            }

            websocket.onerror = (event) => {
                console.error(event);
            }

            websocket.addEventListener('message', (event) => {
                console.debug('message', event.data);
            });

            this.send = (lib, verb, obj = {}) => {
                const uuid = crypto.randomUUID();
                const json = JSON.stringify(
                    Object.assign(obj, {
                        lib: lib,
                        verb: verb,
                        uuid: uuid
                    }));

                websocket.send(json);

                return new Promise((resolve, reject) => {
                    const func = (event) => {

                        const obj = JSON.parse(event.data)

                        if (obj.uuid && obj.uuid === uuid) {

                            if (event.data.error) {
                                reject(event.data);
                            } else {
                                resolve(event.data);
                            }

                            websocket.removeEventListener('message', func);
                        } else {
                            console.log(event.data);
                        }
                    }

                    websocket.addEventListener('message', func);
                });
            }
        }
    }
});
    </script>
</head>

<body>
    <h1>psomium</h1>
    <button
        onclick="psomium.send('sqlite', 'execute', {ms:1000}).then(res=>alert(res)).catch(err=>alert('err'))">TEST1</button>
    <button
        onclick="psomium.send('sqlite', 'execute', {ms: 3000}).then(res=>alert(res)).catch(err=>alert('err'))">TEST3</button>
</body>
</html>
"@

function Wait-Task {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Threading.Tasks.Task[]]$Task
    )
    Begin {
        $Tasks = @()
    }
    Process {
        $Tasks += $Task
    }
    End {
        While (-not [System.Threading.Tasks.Task]::WaitAll($Tasks, 200)) {}
        $Tasks.ForEach( { $_.GetAwaiter().GetResult() })
    }
}
Set-Alias -Name await -Value Wait-Task -Force

$port = 8000

while ($true) {
    try {
        $url = "http://localhost:${port}/"
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($url)
        $listener.Start()
    }
    catch {
        $port = $port + 1
        continue
    }

    break
}

try {
    Start-Process "chromium" -ArgumentList "--app=http://localhost:${port}/"
}
catch {
    try {
        Start-Process "chrome" -ArgumentList "--app=http://localhost:${port}/"
    }
    catch {
        Start-Process "msedge" -ArgumentList "--app=http://localhost:${port}/"
    }
}

while ($listener.IsListening) {

    $context = await $listener.GetContextAsync()
    $requestUrl = $context.Request.Url
    $response = $context.Response
    
    Write-Host ''
    if ($context.Request.IsWebSocketRequest) {    
        Write-Host "> $requestUrl ws"

        $webSocketContext = await $context.AcceptWebSocketAsync(([NullString]::Value))
        $webSocket = $webSocketContext.WebSocket

        $receiveBuffer = [byte[]]::new(1024)
        $inArraySegment = [System.ArraySegment[Byte]]$receiveBuffer

        while ($webSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $result = await $webSocket.ReceiveAsync($inArraySegment, [System.Threading.CancellationToken]::None)

            if ($result.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Close) {
                $message = [System.Text.Encoding]::UTF8.GetString($inArraySegment, 0, $result.Count)

                $json = $message | ConvertFrom-Json

                Write-Host "message: ${json}"
                Write-Host $json.uuid

                $out = $json | ConvertTo-Json
                Start-Sleep -Milliseconds $json.ms

                $messageBuffer = [System.Text.Encoding]::UTF8.GetBytes($out)
                $outArraySegment = [System.ArraySegment[byte]]::new($messageBuffer)

                $task = await $webSocket.SendAsync(
                    $outArraySegment,
                    [System.Net.WebSockets.WebSocketMessageType]::Text, 
                    $true, 
                    [System.Threading.CancellationToken]::None
                )
            }
            else {
                Write-Host "Close Connection"
                $task = $webSocket.CloseAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    "NormalClosure",
                    [System.Threading.CancellationToken]::None
                )
                break;
            }
        }
        $listener.close()
        exit 0
    }
    else {
    
        Write-Host "> $requestUrl http"

        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        $response.ContentLength64 = $buffer.Length
        $response.StatusCode = 200
        $response.OutputStream.Write($buffer, 0, $buffer.Length)

        $response.Close()
    }
}
