#!/bin/bash
# 安装和更新第三方软件包
# 此脚本在 openwrt/package/ 目录下运行，在 feeds install 之后执行

echo "Starting package updates..."

UPDATE_PACKAGE() {
	local -n PKG_NAMES=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local REPO_NAME=${PKG_REPO#*/}

	echo " "
	echo "=========================================="
	(IFS=" | "; echo "Processing: ${PKG_NAMES[*]} from $PKG_REPO, repository: $REPO_NAME, branch: $PKG_BRANCH" )
	echo "=========================================="

	# 删除 feeds 中可能存在的同名软件包
	for NAME in "${PKG_NAMES[@]}"; do
	    if [ -z "$NAME" ]; then
		    continue
		fi
		
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		if [ -n "$FOUND_DIRS" ]; then
		    while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"

	if [ ! -d "$REPO_NAME" ]; then
	    ls
		echo "ERROR: Failed to clone $PKG_REPO"
		return 1
	fi

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
	   for NAME in "${PKG_NAMES[@]}"; do
		    if [[ "$REPO_NAME" == "$NAME" ]]; then
			   echo "Rename repository folder to ${REPO_NAME}1 as it is same as target pkg folder"
			   mv ./$REPO_NAME ./${REPO_NAME}1
			   REPO_NAME=${REPO_NAME}1
			   break
			fi
		done
		# 从大杂烩仓库中提取特定包
		for NAME in "${PKG_NAMES[@]}"; do
	        if [ -z "$NAME" ]; then
		        continue
		    fi
		    find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$NAME*" -prune -exec cp -rf {} ./ \;
		done
		rm -rf ./$REPO_NAME/
	# elif [[ "$PKG_SPECIAL" == "name" ]]; then
		# 重命名仓库
	#	mv -f $REPO_NAME $PKG_NAME
	fi
	
    (IFS=" | "; echo "Done: ${PKG_NAMES[*]}")
}

# 首先删除 feeds 中的 sing-box 相关包，避免与第三方包冲突
echo " "
echo "=========================================="
echo "Removing conflicting sing-box packages from feeds..."
echo "=========================================="
rm -rf ../feeds/packages/net/sing-box
rm -rf ../package/feeds/packages/sing-box
echo "Done removing sing-box from feeds"

# HomeProxy (代理软件) - 使用第5个参数指定额外要删除的包名
pkgs=("sing-box" "luci-app-homeproxy"); UPDATE_PACKAGE pkgs "ericyin/luci-app-homeproxy" "main" "pkg"; unset pkgs
#pkgs=("homeproxy"); UPDATE_PACKAGE pkgs "immortalwrt/homeproxy" "master"; unset pkgs

# soc status app
#pkgs=("luci-app-airoha-npu"); UPDATE_PACKAGE pkgs "ericyin/luci-app-airoha-npu" "main"; unset pkgs
#sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' ./luci-app-airoha-npu/Makefile

# file explorer
#pkgs=("luci-app-quickfile-go"); UPDATE_PACKAGE pkgs "ericyin/luci-app-quickfile-go" "main" "pkg"; unset pkgs

# 
# Argon 主题
#pkgs=("luci-theme-argon"); UPDATE_PACKAGE pkgs "jerrykuku/luci-theme-argon" "master"; unset pkgs
#pkgs=("luci-app-argon-config"); UPDATE_PACKAGE pkgs "jerrykuku/luci-app-argon-config" "master"; unset pkgs

echo " "
echo "=========================================="
echo "Package updates completed, list packages folder: "
ls
echo "=========================================="
