
%include "haka/swig.i"
%{
#include "haka/packet.h"
#include "haka/log.h"
extern void lua_registersingleton(lua_State *L,struct packet *pkt, int new_obj_index, swig_type_info * type_info);
extern void lua_getsingleton(lua_State *L,struct packet *pkt, swig_type_info * type_info);
%}


%define CHECK_FOR_PACKET(TYPE,TYPENAME)
%typemap(check) TYPE {
        // check that the packet hasn't been sent yet
        if(!$1) {
                lua_pushstring(L,"$symname : Using a TYPENAME object that was already sent");
                SWIG_fail;
        }


}
%enddef

%define PACKET_DEPENDANT_CONSTRUCTOR(function,pkt,type_info)
        %exception function {
                lua_getsingleton(L,pkt,type_info);
                if(lua_isnil(L,-1)) {
                        lua_pop(L,1);
                        DEFAULT_EXCEPTION;
                        SWIG_NewPointerObj(L,result,type_info,0); SWIG_arg++; 
                        lua_registersingleton(L,pkt,-1,type_info);
                        return 1;
                }else {
                        // reused object is on top of the stack
                        return 1;
                }
        }
%enddef

%define PACKET_DEPENDANT_GETTER(function,pkt,type_info)
        %exception function {
                DEFAULT_EXCEPTION;
                lua_getsingleton(L,pkt,type_info);
                if(lua_isnil(L,-1) && pkt) {
                        lua_pushstring(L,"internal error : function returning an unknown packet (already sent ?)");
                        SWIG_fail;
                }else {
                        // reused object is on top of the stack
                        return 1;
                }
        }
%enddef

CHECK_FOR_PACKET(struct packet*,packet)

