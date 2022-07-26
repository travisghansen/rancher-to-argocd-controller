FROM flant/shell-operator:v1.0.10

RUN \
  case $(uname -m) in \
    x86_64) \
      wget -O /usr/local/bin/yq 'https://github.com/mikefarah/yq/releases/download/v4.26.1/yq_linux_amd64' \
      ;; \
    armv7l) \
      wget -O /usr/local/bin/yq 'https://github.com/mikefarah/yq/releases/download/v4.26.1/yq_linux_arm' \
      ;; \
    aarch64) \
      wget -O /usr/local/bin/yq 'https://github.com/mikefarah/yq/releases/download/v4.26.1/yq_linux_arm64' \
      ;; \
    *) \
      exit 1 \
      ;; \
  esac && \ 
  chmod +x /usr/local/bin/yq;
ADD hooks/* /hooks
