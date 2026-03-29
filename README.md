```
cd /root && rm -rf emby-worker && \
git clone https://github.com/OneQ1st/emby.git && \
cd emby-worker && \
chmod +x emby.sh && \
sudo cp emby.sh /usr/local/bin/emby && \
sudo chmod +x /usr/local/bin/emby && \
sudo ./emby.sh
```
