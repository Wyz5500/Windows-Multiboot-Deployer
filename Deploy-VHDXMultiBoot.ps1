##################################################

#设置部分
$isoPath = ""
$name = ""
$vhdxDirPath = "C:\"
$vhdxSize = 64GB
$imageIndex = 1

##################################################

#可选设置
$unattendedFilePath = "$($PSScriptRoot)\autounattend.xml"

##################################################

#设置脚本遇到异常情况的默认行为
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues = @{'*:ErrorAction'='Stop'}

##################################################

#函数定义部分
$vhdxPath = [System.IO.Path]::Combine("$vhdxDirPath", "$($Name).vhdx")

function vhdxCreate {
    param (
        [string]$vhdxPath,
        [Int64]$vhdxSize
    )
    $vhdxInfo = @{
        Path = $vhdxPath
        SizeBytes = $vhdxSize
    }
    Write-Host "创建虚拟硬盘……" -ForegroundColor DarkGray
    $null = New-VHD @vhdxInfo -Fixed
}
function installWindows {
    param (
        [string]$isoPath,
        [string]$vhdxPath,
        [Int16]$imageIndex,
        [string]$unattendedFilePath,
        [string]$name
    )
    Write-Host "挂载 iso 镜像……" -ForegroundColor DarkGray
    $image = Mount-DiskImage -ImagePath $isoPath -PassThru
    $installer = Get-Volume -DiskImage $image | Select-Object -First 1
    $windowsImage = "$($installer.DriveLetter):\sources\install.esd"
    if (-not (Test-Path $windowsImage)) {
        $windowsImage = "$($installer.DriveLetter):\sources\install.wim"
    }

    #$version = Get-WindowsImage -ImagePath $windowsImage

    Write-Host "挂载虚拟硬盘……" -ForegroundColor DarkGray
    $vhdx = Mount-VHD -Path $vhdxPath -Passthru     #vhdx对象，vhdx的挂载情况
    $disk = Get-Disk -Number $vhdx.DiskNumber       #disk对象，disk的具体信息

    Write-Host "初始化虚拟硬盘……" -ForegroundColor DarkGray
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT

    Write-Host "为虚拟硬盘新建系统分区……" -ForegroundColor DarkGray
    $ntfs = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $null = Format-Volume -Partition $ntfs -FileSystem NTFS -NewFileSystemLabel $name

    Write-Host "安装 Windows 到虚拟硬盘……" -ForegroundColor DarkGray
    $windowsDir = "$((Get-Volume -Partition $ntfs).DriveLetter):\"
    Dism /Apply-Image /index:"$imageIndex" /ImageFile:"$windowsImage" /ApplyDir:"$windowsDir"
    if ($LASTEXITCODE -ne 0) {throw "Windows 安装失败……"}

    # $efiDir = "$((Get-Volume -Partition $efi).DriveLetter):\"
    # $null = $efiDir
    $windowsPath = [System.IO.Path]::Combine($windowsDir, "Windows")
    # bcdboot "$windowsPath" /s "$efiDir" /f UEFI /l zh-CN *>$null
    # if ($LASTEXITCODE -ne 0) {throw "引导项添加失败……"}

    # 将 VHDX 系统引导项添加到当前OS引导
    # $hostDisk = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
    # $hostEsp = Get-Partition -DiskNumber $hostDisk |
    #     Where-Object GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}' |
    #     Select-Object -First 1
    # $hostEspPath = ($hostEsp | Get-Volume).Path

    # 将主机EFI分区挂载到"C:\mnt\esp"
    Write-Host "挂载主机 EFI 分区……" -ForegroundColor DarkGray
    $mntDir = "C:\mnt\esp"
    $null = New-Item -Path $mntDir -ItemType Directory -Force
    $hostSysDisk = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
    $esp = Get-Partition -DiskNumber $hostSysDisk |
        Where-Object GptType -eq '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    $null = $esp | Add-PartitionAccessPath -AccessPath $mntDir

    # 将 VHDX 系统引导项添加到当前OS引导
    Write-Host "添加 Windows 启动引导……" -ForegroundColor DarkGray
    bcdboot $windowsPath /s $mntDir /f ALL /l zh-cn
    if ($LASTEXITCODE -ne 0) {throw "引导添加失败……"}

    $null = $esp | Remove-PartitionAccessPath -AccessPath $mntDir
    $null = Remove-Item $mntDir -Recurse -Force



    Write-Host "尝试搜索并应用 Autounattend.xml……" -ForegroundColor DarkGray
    if (Test-Path -Path $unattendedFilePath) {
        $null = New-Item -Path "$($windowsPath)\Panther\" -ItemType Directory
        $null = Copy-Item -Path "$unattendedFilePath" -Destination "$($windowsPath)\Panther\unattend.xml"
    }

    Write-Host "卸载 iso 镜像和虚拟硬盘……" -ForegroundColor DarkGray
    $null = Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
    $null = Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
}

##################################################

#参数设置部分
$vhdxCreateParam = @{
    vhdxPath = $vhdxPath
    vhdxSize = $vhdxSize
}
$installWindowsParam = @{
    isoPath = $isoPath
    vhdxPath = $vhdxPath
    imageIndex = $imageIndex
    unattendedFilePath = $unattendedFilePath
    name = $name
}

##################################################

#函数执行部分
if (Test-Path -Path $vhdxPath) {
    Write-Host "虚拟硬盘文件 `"$($vhdxPath)`" 已存在……" -ForegroundColor Red
} else {
    try {
        vhdxCreate @vhdxCreateParam
        installWindows @installWindowsParam
        Write-Host "Windows 系统部署完成" -ForegroundColor Green
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host "正在清理……" -ForegroundColor DarkGray
        $null = Dismount-VHD -Path $vhdxPath -ErrorAction SilentlyContinue
        $null = Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        $null = Remove-Item -Path $vhdxPath -ErrorAction SilentlyContinue
    }
}
