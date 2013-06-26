include(FindPackageHandleStandardArgs)

find_program(SPHINX_EXECUTABLE NAMES sphinx-build
	HINTS $ENV{SPHINX_DIR}
	PATH_SUFFIXES bin
	DOC "Sphinx documentation generator"
)

if(SPHINX_EXECUTABLE)
	set(SPHINX_FOUND)
endif(SPHINX_EXECUTABLE)

FIND_PACKAGE_HANDLE_STANDARD_ARGS(Sphinx DEFAULT_MSG SPHINX_EXECUTABLE)
MARK_AS_ADVANCED(SPHINX_EXECUTABLE)