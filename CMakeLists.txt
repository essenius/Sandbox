# Couple of handy CMake snippets

# write contents of a folder to a file
file(GLOB sources_list LIST_DIRECTORIES true *)
foreach(dir ${sources_list})
    IF(IS_DIRECTORY ${dir})
    file(APPEND ${PROJECT_BINARY_DIR}/output.txt "dir=${dir}\n")
    ELSE()
    file(APPEND ${PROJECT_BINARY_DIR}/output.txt "file=${dir}\n")
    ENDIF()
endforeach()

# show all variables starting with CMAKE. 
get_cmake_property(_variableNames VARIABLES)
list (SORT _variableNames)
foreach (_variableName ${_variableNames})
    string(FIND "${_variableName}" "CMAKE" _pos)
    if(_pos EQUAL 0)
        message(STATUS "${_variableName}=${${_variableName}}")
    endif()
endforeach()

# use all .h / .cpp files in a folder 
file(GLOB_RECURSE myHeaders LIST_DIRECTORIES true *.h)
file(GLOB_RECURSE mySources LIST_DIRECTORIES true *.cpp)
