#!/bin/sh

set -e

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh && safe_source "$INST_CONF"
ensure_arch || exit 1
apply_github_mode

GITHUB_API_LATEST_RELEASE_URL_SUFFIX="repos/${GITHUB_RELEASE_REPO}/releases/latest"

valid_release_tag() {
	case "$1" in
		v*) return 0 ;;
		*) return 1 ;;
	esac
}

parse_tag_from_json() {
	local json="$1"
	local version=""

	if command -v jq >/dev/null 2>&1; then
		version=$(echo "$json" | jq -r '.tag_name // empty')
	else
		version=$(echo "$json" \
			| grep -o '"tag_name"[ ]*:[ ]*"[^"]*"' \
			| sed 's/.*"tag_name"[ ]*:[ ]*"\([^"]*\)".*/\1/' \
			| head -n1)
	fi

	if valid_release_tag "$version"; then
		echo "$version"
		return 0
	fi
	return 1
}

fetch_latest_json() {
	local api_url="$1"
	local tmp_json_file="/tmp/github_latest_release.json"
	local json=""

	if ! webget "$tmp_json_file" "$api_url" "echooff"; then
		return 1
	fi

	json=$(cat "$tmp_json_file")
	rm -f "$tmp_json_file"
	parse_tag_from_json "$json"
}

# 通过 releases/latest 重定向解析版本（不依赖 api.github.com）
get_latest_version_from_redirect() {
	local suffix="${GITHUB_RELEASE_REPO}/releases/latest/download/SHA256SUMS.txt"
	local mirror_list resolved effective version

	try_redirect() {
		local prefix="$1"
		local label="$2"

		effective=$(webget_effective_url "${prefix}https://github.com/${suffix}") || return 1
		version=$(parse_release_tag_from_url "$effective")
		if valid_release_tag "$version"; then
			log_info "🔗  ${label}: $version"
			echo "$version"
			return 0
		fi
		return 1
	}

	try_redirect "" "Release 重定向解析版本" && return 0

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

# 获取最新版本：API → Release 重定向 → API 镜像 → release.conf 回退
get_latest_version() {
	local mirror_list
	local api_url="${CUSTOM_API_PROXY}/${GITHUB_API_LATEST_RELEASE_URL_SUFFIX}"
	local version=""

	version=$(fetch_latest_json "$api_url") && {
		echo "$version"
		return 0
	}

	version=$(get_latest_version_from_redirect) && {
		echo "$version"
		return 0
	}

	mirror_list=$(resolve_mirror_list "$MIRROR_LIST")
	if [ -n "$mirror_list" ] && [ -f "$mirror_list" ]; then
		while read -r mirror; do
			mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -z "$mirror" ] && continue
			mirror=$(echo "$mirror" | sed 's|/*$|/|')
			api_url="${mirror}https://api.github.com/${GITHUB_API_LATEST_RELEASE_URL_SUFFIX}"
			log_info "🔗  尝试 API 镜像: $api_url"
			version=$(fetch_latest_json "$api_url") && {
				echo "$version"
				return 0
			}
		done < "$mirror_list"
	fi

	if [ -n "${DEFAULT_RELEASE_VERSION:-}" ] && valid_release_tag "$DEFAULT_RELEASE_VERSION"; then
		log_warn "⚠️  在线获取版本失败，使用 release.conf 指定版本: $DEFAULT_RELEASE_VERSION"
		echo "$DEFAULT_RELEASE_VERSION"
		return 0
	fi

	log_error "❌  错误：无法在线获取版本（GitHub API / 重定向 / 镜像均失败）"
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
        if [ $rc -eq 0 ] && valid_release_tag "$candidate"; then
            VERSION="$candidate"
            break
        fi
        VERSION=""
        retry=$((retry + 1))
        log_warn "⚠️  获取最新版本失败 ($retry/$max_retry)，重试中..."
        sleep 2
    done
    set -e
    if ! valid_release_tag "$VERSION"; then
        log_error "❌  无法获取最新版本，已重试 $max_retry 次"
        exit 1
    fi
fi

if [ "$DRY_RUN" = "true" ]; then
    echo "$VERSION"
    exit 0
fi

install_tailscale "$VERSION" "$MIRROR_LIST"
