echo "Installing dependencies"
pnpm bootstrap

echo "Building nc-gui"
cd .\packages\nc-gui
pnpm run generate

echo "Copying nc-gui to nocodb"
cd ..\nocodb
$ncGuiDistPath= ".\docker\nc-gui"
if (Test-Path -Path $ncGuiDistPath) {
    # Remove the folder and its contents
    Remove-Item -Path $ncGuiDistPath -Recurse -Force
    Write-Output "Cleaned $ncGuiDistPath"
}
cp -r ..\nc-gui\dist $ncGuiDistPath

echo "Building nocodb"
[Environment]::SetEnvironmentVariable('EE','true') 
.\node_modules\.bin\webpack-cli.ps1 --config .\webpack.local.config.js
[Environment]::SetEnvironmentVariable('EE','')

echo "Build docker image"
docker build  -f Dockerfile.local -t hnhuyit/digital79:digital .