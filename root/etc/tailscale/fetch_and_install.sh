#!/bin/sh

set -e

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh && safe_source "$INST_CONF"
ensure_arch || exit 1
apply_github_mode

GITHUB_API_LATEST_RELEASE_URL_SUFFIX="repos/${GITHUB_RELEASE_REPO}/releases/latest"
GITHUB_API_RELEASES_LIST_SUFFIX="repos/${GITHUB_RELEASE_REPO}/releases?per_page=30"

parse_tag_from_json() {
	local json_file="$1"
	local version=""

	if command -v jq >/dev/null 2>&1; then
		version=$(jq -r '.tag_name // empty' "$json_file" 2>/dev/null)
	else
		version=$(grep -o '"tag_name"[ ]*:[ ]*"[^"]*"' "$json_file" \
			| sed 's/.*"tag_name"[ ]*:[ ]*"\([^"]*\)".*/\1/' \
			| head -n1)
	fi

	if is_tailscale_binary_tag "$version"; then
		echo "$version"
		return 0
	fi
	return 1
}

parse_first_binary_tag_from_list_json() {
	local json_file="$1"
	local version=""

	if command -v jq >/dev/null 2>&1; then
		version=$(jq -r '[.[] | .tag_name | select(test("^v[0-9]"))] | .[0] // empty' "$json_file" 2>/dev/null)
	else
		version=$(grep -o '"tag_name"[ ]*:[ ]*"v[0-9][^"]*"' "$json_file" \
			| head -n1 \
			| sed 's/.*"tag_name"[ ]*:[ ]*"\([^"]*\)".*/\1/')
	fi

	if is_tailscale_binary_tag "$version"; then
		echo "$version"
		return 0
	fi
	return 1
}

# 从 releases 列表取最新 tailscaled 二进制 tag（避免 luci-v* 被标为 latest）
fetch_latest_binary_tag_from_list() {
	local prefix="${1:-}"
	local api_url="${prefix}${CUSTOM_API_PROXY}/${GITHUB_API_RELEASES_LIST_SUFFIX}"
	local tmp_json="/tmp/github_releases_list.json"
	local version

	if ! webget "$tmp_json" "$api_url" "echooff"; then
		return 1
	fi

	version=$(parse_first_binary_tag_from_list_json "$tmp_json")
	rm -f "$tmp_json"
	[ -n "$version" ] && echo "$version" && return 0
	return 1
}

fetch_latest_json() {
	local api_url="$1"
	local tmp_json_file="/tmp/github_latest_release.json"

	if ! webget "$tmp_json_file" "$api_url" "echooff"; then
		return 1
	fi

	parse_tag_from_json "$tmp_json_file"
	local rc=$?
	rm -f "$tmp_json_file"
	return $rc
}

# 通过 releases/latest 重定向解析版本（不依赖 api.github.com）
get_latest_version_from_redirect() {
	local suffix="${GITHUB_RELEASE_REPO}/releases/latest/download/SHA256SUMS.txt"
	local mirror_list effective version

	try_redirect() {
		local prefix="$1"
		local label="$2"

		effective=$(webget_effective_url "${prefix}https://github.com/${suffix}") || return 1
		version=$(parse_release_tag_from_url "$effective")
		if is_tailscale_binary_tag "$version"; then
			log_info "🔗  ${label}: $version"
			echo "$version"
			return 0
		fi
		return 1
	}

	try_redirect "" "Release 重定向解析版本" && return 0

	[ "$GITHUB_DIRECT" = "true" ] && return 1

	mirror_list=$(resolve_mirror_list "$MIRROR_LIST")
	if [ -n "$mirror_list" ] && [ -f "$mirror_list" ]; then
		while read -r mirror; do
			mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -z "$mirror" ] && continue
			mirror=$(echo "$mirror" | sed 's|/*$|/|')
			try_redirect "$mirror" "镜像 Release 重定向" && return 0
		done < "$mirror_list"
	fi
	return 1
}

# 获取最新 tailscaled 版本：列表 API → latest API → 重定向 →（非直连时）镜像 → release.conf
get_latest_version() {
	local mirror_list
	local api_url="${CUSTOM_API_PROXY}/${GITHUB_API_LATEST_RELEASE_URL_SUFFIX}"
	local version=""

	version=$(fetch_latest_binary_tag_from_list) && {
		log_info "📦  最新 tailscaled: $version"
		echo "$version"
		return 0
	}

	version=$(fetch_latest_json "$api_url") && {
		echo "$version"
		return 0
	}

	version=$(get_latest_version_from_redirect) && {
		echo "$version"
		return 0
	}

	if [ "$GITHUB_DIRECT" != "true" ]; then
		mirror_list=$(resolve_mirror_list "$MIRROR_LIST")
		if [ -n "$mirror_list" ] && [ -f "$mirror_list" ]; then
			while read -r mirror; do
				mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
				[ -z "$mirror" ] && continue
				mirror=$(echo "$mirror" | sed 's|/*$|/|')
				log_info "🔗  尝试 releases 列表镜像: ${mirror}https://api.github.com/${GITHUB_API_RELEASES_LIST_SUFFIX}"
				version=$(fetch_latest_binary_tag_from_list "$mirror") && {
					echo "$version"
					return 0
				}
				api_url="${mirror}https://api.github.com/${GITHUB_API_LATEST_RELEASE_URL_SUFFIX}"
				log_info "🔗  尝试 API 镜像: $api_url"
				version=$(fetch_latest_json "$api_url") && {
					echo "$version"
					return 0
				}
			done < "$mirror_list"
		fi
	fi

	if [ -n "${DEFAULT_RELEASE_VERSION:-}" ] && is_tailscale_binary_tag "$DEFAULT_RELEASE_VERSION"; then
		log_warn "⚠️  在线获取版本失败，使用 release.conf 指定版本: $DEFAULT_RELEASE_VERSION"
		echo "$DEFAULT_RELEASE_VERSION"
		return 0
	fi

	if [ "$GITHUB_DIRECT" = "true" ]; then
		log_error "❌  错误：GitHub 直连无法解析 tailscaled 版本（仓库 latest 可能为 luci 包，请检查 release.conf 或网络）"
	else
		log_error "❌  错误：无法在线获取版本（GitHub / 镜像均失败）"
	fi
	return 1
}

get_checksum() {
    local sums_file=$1
    local target_name=$2
    grep "$target_name" "$sums_file" | grep -v "${target_name}.build" | awk '{print $1}'
}

download_file() {
    local url=$1
    local output=$2
    local mirror_list=${3:-}
    local checksum=${4:-}
    local resolved_mirrors

    if [ "$GITHUB_DIRECT" = "true" ] ; then
        log_info "📄  使用 GitHub 直连: https://github.com/$url"
        if webget "$output" "https://github.com/$url" "echooff"; then
            [ -n "$checksum" ] && verify_checksum "$output" "$checksum"
            return 0
        else
            return 1
        fi
    fi

    resolved_mirrors=$(resolve_mirror_list "$mirror_list")
    if [ -n "$resolved_mirrors" ] && [ -f "$resolved_mirrors" ]; then
        while read -r mirror; do
            mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
            [ -z "$mirror" ] && continue
            mirror=$(echo "$mirror" | sed 's|/*$|/|')
            log_info "🔗  使用代理镜像下载: ${mirror}https://github.com/$url"
            if webget "$output" "${mirror}https://github.com/$url" "echooff"; then
                if [ -n "$checksum" ]; then
                    if verify_checksum "$output" "$checksum"; then
                        return 0
                    else
                        log_warn "⚠️  校验失败，尝试下一个镜像..."
                    fi
                else
                    return 0
                fi
            fi
        done < "$resolved_mirrors"
    fi

    log_info "🔗  镜像全部失败，尝试 GitHub 直连: https://github.com/$url"
    if webget "$output" "https://github.com/$url" "echooff"; then
        [ -n "$checksum" ] && verify_checksum "$output" "$checksum"
        return 0
    else
        return 1
    fi
}

install_tailscale() {
    local version=$1
    local mirror_list=$2

    local arch="$ARCH"
    local tailscale_temp_path="/tmp/tailscaled.$$"
    local release_arch_filename="tailscaled-linux-$arch"
    local release_version_suffix="${GITHUB_RELEASE_REPO}/releases/download/$version"

    log_info "🔗  准备校验文件..."
    sha_file="/tmp/SHA256SUMS.$$"
    md5_file="/tmp/MD5SUMS.$$"

    download_file "${release_version_suffix}/SHA256SUMS.txt" "$sha_file" "$mirror_list" || log_warn "⚠️  无法获取 SHA256 校验文件"
    download_file "${release_version_suffix}/MD5SUMS.txt" "$md5_file" "$mirror_list" || log_warn "⚠️  无法获取 MD5 校验文件"

    sha256=""
    md5=""
    [ -s "$sha_file" ] && sha256=$(get_checksum "$sha_file" "$release_arch_filename")
    [ -s "$md5_file" ] && md5=$(get_checksum "$md5_file" "$release_arch_filename")

    log_info "🔗  正在下载 Tailscale $version ($arch)..."
    if ! download_file "${release_version_suffix}/$release_arch_filename" "$tailscale_temp_path" "$mirror_list" "$sha256"; then
        log_warn "⚠️  SHA256 校验失败，尝试 MD5..."
        if ! download_file "${release_version_suffix}/$release_arch_filename" "$tailscale_temp_path" "$mirror_list" "$md5"; then
            log_error "❌  校验失败，安装中止"
            rm -f "$tailscale_temp_path"
            exit 1
        fi
    fi

    chmod +x "$tailscale_temp_path"
    mkdir -p /usr/local/bin
    mv "$tailscale_temp_path" /usr/local/bin/tailscaled
    ln -sf /usr/local/bin/tailscaled /usr/bin/tailscaled
    ln -sf /usr/local/bin/tailscaled /usr/bin/tailscale
    log_info "✅  已安装到 /usr/local/bin/"

    echo "$version" > "$VERSION_FILE"
}

VERSION="latest"
MIRROR_LIST=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --version=*) VERSION="${1#*=}"; shift ;;
        --mirror-list=*) MIRROR_LIST="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --mode=*) shift ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

if [ "$VERSION" = "latest" ]; then
    set +e
    retry=0
    max_retry=3
    VERSION=""
    while [ $retry -lt $max_retry ]; do
        candidate=$(get_latest_version)
        rc=$?
        if [ $rc -eq 0 ] && is_tailscale_binary_tag "$candidate"; then
            VERSION="$candidate"
            break
        fi
        VERSION=""
        retry=$((retry + 1))
        log_warn "⚠️  获取最新版本失败 ($retry/$max_retry)，重试中..."
        sleep 2
    done
    set -e
    if ! is_tailscale_binary_tag "$VERSION"; then
        log_error "❌  无法获取最新版本，已重试 $max_retry 次"
        exit 1
    fi
fi

if [ "$DRY_RUN" = "true" ]; then
    echo "$VERSION"
    exit 0
fi

install_tailscale "$VERSION" "$MIRROR_LIST"
