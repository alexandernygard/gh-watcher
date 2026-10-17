.PHONY: app debug run install clean

app:
	Scripts/build-app.sh release

debug:
	Scripts/build-app.sh debug

run: app
	open "build/GH Watcher.app"

install: app
	rm -rf "/Applications/GH Watcher.app"
	cp -R "build/GH Watcher.app" /Applications/
	open "/Applications/GH Watcher.app"

clean:
	rm -rf .build build
