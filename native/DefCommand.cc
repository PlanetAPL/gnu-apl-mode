#include "NetworkConnection.hh"
#include "DefCommand.hh"
#include "emacs.hh"

#include "Quad_FX.hh"

void DefCommand::run_command( NetworkConnection &conn, const std::vector<std::string> &args )
{
    vector<string> content = conn.load_block();

    Shape shape( content.size() );
    Value_P function_list_value( new Value( shape, LOC ) );
    for( vector<string>::const_iterator i = content.begin() ; i != content.end() ; i++ ) {
        UCS_string s = ucs_string_from_string( *i );
        Shape row_shape( s.size() );
        Value_P row_cell( new Value( row_shape, LOC ) );
        for( int i2 = 0 ; i2 < s.size() ; i2++ ) {
            new (row_cell->next_ravel()) CharCell( s[i2] );
        }
        new (function_list_value->next_ravel()) PointerCell( row_cell );
    }
    function_list_value->check_value( LOC );

    Quad_FX quad_fx;
    Token result = quad_fx.eval_B( function_list_value );
    conn.write_string_to_fd( result.canonical( PST_CS_NONE ).to_string() );
    conn.write_string_to_fd( "\n" END_TAG "\n" );
}
