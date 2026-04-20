.PHONY: up
up:
	docker compose up -d

.PHONY: ps
ps:
	docker ps

.PHONY: down
down:
	docker compose down -v 