.PHONY: health-check

health-check:
	# emojivoto
	curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8090
