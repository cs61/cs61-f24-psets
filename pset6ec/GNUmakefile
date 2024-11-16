# Default optimization level
O ?= 2

all: breakout61

WANT_TSAN = 1
-include build/rules.mk

LIBS = -lm

%.o: %.cc $(BUILDSTAMP)
	$(call run,$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(DEPCFLAGS) $(O) -o $@ -c,COMPILE,$<)

breakout61: board.o breakout61.o helpers.o
	$(call run,$(CXX) $(CXXFLAGS) $(O) -o $@ $^ $(LDFLAGS) $(LIBS),LINK $@)

check: always
	perl check.pl

clean: clean-main
clean-main:
	$(call run,rm -rf breakout61 *.o *~ *.bak core *.core,CLEAN)
	$(call run,rm -rf out *.dSYM $(DEPSDIR))

.PRECIOUS: %.o
.PHONY: all clean clean-main clean-hook distclean run check check-% prepare-check
