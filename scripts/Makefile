MAKEFLAGS += --no-print-directory

HELP_PROJECT_NAME := Amber Scripts
HELP_WIDTH := 20

SCRIPTS := update-versions build-pkgs

##@ Build

build:: $(SCRIPTS) ## Compile all amber scripts

update-versions:: ## Compile update-versions
	@amber build src/update-versions/main.ab $@
	$(call msg-success,"Built $@")

build-pkgs:: ## Compile build-pkgs
	@amber build src/build-pkgs/main.ab $@
	$(call msg-success,"Built $@")

check:: ## Check amber syntax for all scripts
	@amber check src/update-versions/main.ab
	@amber check src/build-pkgs/main.ab
	$(call msg-success,"Syntax OK")

clean:: ## Remove compiled scripts
	@rm -f $(SCRIPTS)
	$(call msg-success,"Cleaned")

##@ Run

run-update-versions:: ## Run update-versions directly
	@amber run src/update-versions/main.ab -- $(RUN_ARGS)

run-build-pkgs:: ## Run build-pkgs directly
	@amber run src/build-pkgs/main.ab -- $(RUN_ARGS)
