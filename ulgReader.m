function fds = ulgReader(file,generate_plots)
% Script for importing ulg files
%
%   fds = ulgReader(file,generate_plots)
%
%      fds: struct containing the log information and data
%      file: input PX4 *.ulg file
%      generate_plots: Optionally generate plots of all the log
%                      data (1)
%
% The file description for ulg files can be found at
% https://docs.px4.io/master/en/dev_log/ulog_file_format.html

tic

%file = 'C:\Users\matt\Downloads\arroyo_crash_20241108.ulg';

if ~exist('file','var')
    [filename, filepath, ~] = uigetfile('*.ulg','Select PX4 ulg file');
    file = fullfile(filepath,filename);
    
    if (all(filename == 0) && all(filepath == 0))
        % Cancel button was pressed
        return
    end
    
end

if ~exist('generate_plots','var')
    generate_plots = 0;
end


% Break up the file names
[filepath, filename, fileext] = fileparts(file);

% Start off all the structs that we're going to need
fds.fileName = [filename,fileext];  % name of .ulg file
fds.filePathName = filepath;        % path to .ulg file

fds.info      = struct(); % Struct for holding the header data
fds.flags     = struct(); % Struct for holding the flags of the file
fds.param     = struct(); % Struct for holding parameters
fds.perf_msgs = struct(); % Struct for holding performance messages
fds.messages  = struct(); % Struct for other message types (string messages)

fds.logs = struct();  % struct for the output data
fds.time_ref_utc = 0;

fds.log_data            = char(0);  % The .ulg file data as a row-matrix of chars (uint8s)
fds.log_msg_def         = struct(); % Struct for holding the log definitions
fds.log_msg_def_padding = struct(); % Struct holding the log definitions without the padding removed
fds.log_msg_size        = struct(); % Struct for holding the size of the messages
fds.log_msg_locs        = struct(); % Struct for holding the locations of each log message


% Import the data
fid = fopen(file,'r');
fds.log_data = fread(fid, [1 inf], '*uchar');
fclose(fid);

% Check the header was a valid ulg file
fds = read_log_header(fds);

% Information starts at offset 0d17
fds.idx = 17;

% Process the file
% Loop through and capture all the log message types, etc.
fprintf('\tProcessing File\n');

len_log_data = numel(fds.log_data);

while fds.idx < len_log_data
    % Read the message header
    [msg_size,msg_type] = read_message_header(fds);
    fds.idx = fds.idx+3;   % Increment the idx based on the size of the header
    %fprintf('%10d / %10d | ',fds.idx,len_log_data);
    %fprintf('Message Type %s, Size %3d\n',msg_type,msg_size);

    % Action based on msg_type
    switch (msg_type)
        case 'B'  % Flag bits
            fds = flag_bitset_message(fds);
        case 'I' % Information
            fds = information_message(fds,msg_size);
        case 'F' % Format
            fds = format_message(fds,msg_size);
        case 'P' % Parameter
            fds = param_message(fds,msg_size);
        case 'M' % Multi-information
            fds = message_message(fds,msg_size);
        case 'A'
            fds = add_logged_message(fds,msg_size);
        case 'D'
            fds = logged_data_message(fds,msg_size);
        case 'L'
            fds = string_message(fds,msg_size);
        case 'S'
            fds = sync_message(fds,msg_size);
        case 'O'
            % Log dropout (let's ignore for now)
            fds.idx = fds.idx + msg_size;
        case 'Q' % Default parameter message
            % let's ignore for now
            fds.idx = fds.idx + msg_size;
        otherwise
            % we've lost out spot, we probably need to just
            % read until we find something we recognise
            fprintf('Don''t recognise type <<%s>>\n',msg_type);
            fds.idx = fds.idx + 1;
            %keyboard
            
    end
    
end

% Process the message formats
fprintf('\tProcessing Message Formats\n');

% Expand out the message formats
fds = expand_message_arrays(fds);    % Expands out arrays
fds = remove_padding(fds);           % Expands out embedded message formats
fds = insert_embedded_messages(fds); % Removes trailing padding
fds = calc_message_sizes(fds);       % Calculates message size

% We should have by now
%   Type, Definitions           (fds.log_msg_def)
%   IDs, Names, Type, Locations (fds.log_msg_locs)
% Now we need to iterate on each and extract the data
fprintf('\tExtracting Data\n');

log_idxs = fieldnames(fds.log_msg_locs);
for ii = 1:numel(log_idxs)
    log_idx = log_idxs{ii};
    fds = extract_data(fds,log_idx);
end

% Remove padding fields
fds = remove_padding_fields(fds);

% Sort the field names alphabetically
fds.logs = orderfields(fds.logs);

% Remove the working struct elements
fds = rmfield(fds,'log_data');
fds = rmfield(fds,'log_msg_def');
fds = rmfield(fds,'log_msg_def_padding');
fds = rmfield(fds,'log_msg_size');
fds = rmfield(fds,'log_msg_locs');
fds = rmfield(fds,'idx');

% Plot stuff to check the import is correct
if (generate_plots)
    fprintf('Generating Check Plots\n');
    make_check_plots(fds);
end

% Display process time on completion
fprintf('File processed in %.2f seconds\n',toc);

end

function fds = read_log_header(fds)
% Check the header is valid
headerMagic = uint8([85,76,111,103,1,18,53]);

fprintf('Reading v%d .ulg file',fds.log_data(8));

if isequal(fds.log_data(1:7),headerMagic)
    % Log file has a valid header
    fprintf(' - Header OK!\n');
else
    % Not what we expected, error out
    fprintf('\n\n');
    error('Error with log file header');
end

% Log time offset
fds.time_ref_utc = typecast(fds.log_data(9:16),'uint64');

end

function [msg_size,msg_type] = read_message_header(fds)
% struct message_header_s {
%   uint16_t msg_size;
%   uint8_t msg_type
% };

msg_size = typecast(fds.log_data(fds.idx:fds.idx+1),'uint16'); ...
    msg_size = double(msg_size);
msg_type = char(fds.log_data(fds.idx+2));

return
end

function fds = flag_bitset_message(fds)
% struct ulog_message_flag_bits_s {
%   struct message_header_s;
%   uint8_t compat_flags[8];
%   uint8_t incompat_flags[8];
%   uint64_t appended_offsets[3]; ///< file offset(s) for appended data if appending bit is set
% };

fds.flags.compat_flags     = fds.log_data(fds.idx:fds.idx+7); ...
    fds.idx = fds.idx+8;
fds.flags.incompat_flags   = fds.log_data(fds.idx:fds.idx+7); ...
    fds.idx = fds.idx+8;
fds.flags.appended_offsets = typecast(fds.log_data(fds.idx:fds.idx+8*3-1),'uint64'); ...
    fds.idx = fds.idx+8*3;
end

function fds = information_message(fds,msg_size)
% struct message_info_s {
% 	struct message_header_s header;
% 	uint8_t key_len;
% 	char key[key_len];
% 	char value[header.msg_size-1-key_len]
% };

key_len = double(fds.log_data(fds.idx)); ...
    fds.idx = fds.idx+1;
key = char(fds.log_data(fds.idx:fds.idx+key_len-1)); ...
    fds.idx = fds.idx+key_len;

[msg_type,msg_name_temp] = strtok(key); ...
    msg_name = msg_name_temp(2:end);

value_data = fds.log_data(fds.idx:fds.idx+msg_size-2-key_len);
fds.idx = fds.idx+msg_size-key_len-1;

switch (msg_type)
    case 'uint32_t'; value = typecast(value_data,'uint32'); value = num2str(value);
    case 'uint64_t'; value = typecast(value_data,'uint64_t'); value = num2str(value);
    case 'int32_t';  value = typecast(value_data,'int32');  value = num2str(value);
    case 'float';    value = typecast(value_data,'single'); value = num2str(value);
    otherwise
        if contains(msg_type,'char')
            value = char(value_data);
        else
            fprintf('Unrecognised type %s\n',msg_type);
            keyboard
        end
end

% Create info struct in the object
fds.info.(msg_name) = value;

% Debugging
% fprintf('\tParam: %s (%s)\n',msg_name,msg_type);
% fprintf('\t\tMessage: %s\n',value);

return
end

function fds = expand_message_arrays(fds)
% Function for exapanding out the message formats
% In some cases, message formats have other message formats
% embedded (or padding), so we need to expand all that

log_types = fieldnames(fds.log_msg_def);

% Expand out arrays
for ii = 1:numel(log_types)
    % Expand everything out
    log_name = log_types{ii};
    log_def = fds.log_msg_def.(log_name);
    
    % Extract field names and types
    fields = fieldnames(log_def);
    types  = fields;
    for jj = 1:numel(fields)
        types{jj} = log_def.(fields{jj});
    end
    
    % Loop from the bottom up and create a new, expanded
    % version of the log fields
    idx_field = numel(fields);
    
    while idx_field > 0
        % Examine fields
        field   = fields{idx_field};
        varType = types{idx_field};
        
        % First check if it is a multiple field type
        if contains(varType,'[')
            %fprintf('\t\tExpanding (%s) %s\n',varType,field);
            loc_in = strfind(varType,'[');
            loc_out = strfind(varType,']');
            
            % Work out array size
            array_type = varType(1:loc_in-1);
            array_size = str2double(varType(loc_in+1:loc_out-1));
            
            % Save the values either size of the fields cell
            % array
            if (idx_field == 1)
                fields_before = {};
                types_before  = {};
            else
                fields_before = fields(1:idx_field-1);
                types_before  = types(1:idx_field-1);
            end
            
            if (idx_field == numel(fields))
                fields_after = {};
                types_after  = {};
            else
                fields_after  = fields(idx_field+1:end);
                types_after   = types(idx_field+1:end);
            end
            
            fields_new = cell(array_size,1);
            types_new =  cell(array_size,1);
            
            for jj = 1:array_size
                fields_new{jj} = [field,'_',num2str(jj-1)];
                types_new{jj}  = array_type;
            end
            
            
            % Combine arrays back together
            fields = [fields_before;fields_new;fields_after];
            types  = [types_before;types_new;types_after];
            
        end
        
        % Decrement the current field we're looking at
        idx_field = idx_field - 1;
        
    end
    
    % Remove the original field
    fds.log_msg_def = rmfield(fds.log_msg_def,log_name);
    
    % Save the information back into the main msg_def_struct
    for jj = 1:numel(fields)
        fds.log_msg_def.(log_name).(fields{jj}) = types{jj};
    end
    
end

return
end

function fds = insert_embedded_messages(fds)
% Expand out embedded definitions
log_types = fieldnames(fds.log_msg_def);

for ii = 1:numel(log_types)
    % Expand everything out
    log_name = log_types{ii};
    log_def = fds.log_msg_def.(log_name);
    
    % Extract field names and types
    fields = fieldnames(log_def);
    types  = fields;
    for jj = 1:numel(fields)
        types{jj} = log_def.(fields{jj});
    end
    
    % Loop from the bottom up and create a new, expanded
    % version of the log fields
    idx_field = numel(fields);
    
    while idx_field > 0
        % Examine fields
        field   = fields{idx_field};
        varType = types{idx_field};
        
        % Check if varType is legit is an embedded type
        if isnan(getVarSize(varType))
            %fprintf('\t\tFilling %s type into %s\n',varType,log_name);
            
            % Must be something embedded, expand it out
            % Save the values either size of the fields cell array
            if (idx_field == 1)
                fields_before = {};
                types_before  = {};
            else
                fields_before = fields(1:idx_field-1);
                types_before  = types(1:idx_field-1);
            end
            
            if (idx_field == numel(fields))
                fields_after = {};
                types_after  = {};
            else
                fields_after  = fields(idx_field+1:end);
                types_after   = types(idx_field+1:end);
            end
            
            embedded_def = fds.log_msg_def_padding.(varType);
            fields_new = fieldnames(embedded_def);
            types_new = fields_new;
            
            
            for jj = 1:numel(fields_new)
                types_new{jj} = embedded_def.(fields_new{jj});
                % Prefix the field with the name of the
                % embedded format
                fields_new{jj} = [field,'__',fields_new{jj}];
                
            end
            
            % Combine arrays back together
            fields = [fields_before;fields_new;fields_after];
            types  = [types_before;types_new;types_after];
            
            % Increment the current field to the end of the newly-added fields
            idx_field = idx_field + numel(fields_new);
            
        end
        
        % Decrement the current field we're looking at
        idx_field = idx_field - 1;
        
    end
    
    % Remove the original field
    fds.log_msg_def = rmfield(fds.log_msg_def,log_name);
    
    % Save the information back into the main msg_def_struct
    for jj = 1:numel(fields)
        fds.log_msg_def.(log_name).(fields{jj}) = types{jj};
    end
end

return
end

function fds = remove_padding(fds)
% Remove the padding at the end of each log type
log_types = fieldnames(fds.log_msg_def);

% Store a backup of the log messages with padding
fds.log_msg_def_padding = fds.log_msg_def;

for ii = 1:numel(log_types)
    
    log_name = log_types{ii};
    field_names = fieldnames(fds.log_msg_def.(log_name));
    
    % Loop through and remove padding
    while contains(field_names{end},'padding0')
        fds.log_msg_def.(log_name) = rmfield(fds.log_msg_def.(log_name),field_names{end});
        field_names = fieldnames(fds.log_msg_def.(log_name));
    end
end

return
end

function fds = calc_message_sizes(fds)
% Remove the padding at the end of each log type
log_types = fieldnames(fds.log_msg_def);

% Store a backup of the log messages with padding
fds.log_msg_def_padding = fds.log_msg_def;

for ii = 1:numel(log_types)
    
    log_name = log_types{ii};
    msg_size = 0;
    
    % Work out the size of the message
    fields = fieldnames(fds.log_msg_def.(log_name));
    for jj = 1:numel(fields)
        msg_size = msg_size + getVarSize(fds.log_msg_def.(log_name).(fields{jj}));
        
    end
    
    fds.log_msg_size.(log_name) = msg_size;
    
end

return;
end

function fds = format_message(fds,msg_size)
% Function for storing raw message formats

% struct message_format_s {
%   struct message_header_s header;
%   char format[header.msg_size];
% };
format = char(fds.log_data(fds.idx:fds.idx+msg_size-1));
fds.idx = fds.idx + msg_size;

% Name of the field is first
name_loc = strfind(format,':');
name = format(1:name_loc-1);
format = format(name_loc+1:end);

% Create strut for storing block format
fds.log_msg_def.(name) = struct();

% The rest are fields
field_locs = strfind(format,';');
field_locs = [ 0, field_locs ];

% fprintf('\tLog Message: %s\n',name);
for ii = 2:numel(field_locs)
    xx = format(field_locs(ii-1)+1:field_locs(ii)-1);
    [field_type,field_name] = strtok(xx);
    
    % Sanitise field_name string
    if (strcmp(field_name(1),' ')); field_name(1) = []; end
    if (strcmp(field_name(1),'_')); field_name(1) = []; end
    
    % Standard add field type to struct
    fds.log_msg_def.(name).(field_name) = field_type;
    
    %fprintf('\t\t%s (%s)\n',field_name,field_type);
end

return
end

function fds = param_message(fds,msg_size)
% struct message_info_s {
%   struct message_header_s header;
%   uint8_t key_len;
%   char key[key_len];
%   char value[header.msg_size-1-key_len]
% };

key_len = double(fds.log_data(fds.idx)); ...
    fds.idx = fds.idx+1;
key = char(fds.log_data(fds.idx:fds.idx+key_len-1)); ...
    fds.idx = fds.idx+key_len;

[param_type,param_name_temp] = strtok(key); ...
    param_name = param_name_temp(2:end);

value_data = fds.log_data(fds.idx:fds.idx+msg_size-2-key_len);
fds.idx = fds.idx+msg_size-key_len-1;

switch (param_type)
    case 'uint32_t'; value = typecast(value_data,'uint32');
    case 'int32_t';  value = typecast(value_data,'int32');
    case 'float';    value = typecast(value_data,'single');
    otherwise; keyboard; return;
end

% Store the param in the param field of the fds
fds.param.(param_name) = value;

% Debugging
% fprintf('\tParam: %s (%s)\n',param_name,param_type);
% fprintf('\t\tValue: %s\n',num2str(value));

return
end

function fds = message_message(fds,~)
% struct ulog_message_info_multiple_header_s {
% struct message_header_s header;
%   uint8_t is_continued; ///< can be used for arrays
%   uint8_t key_len;
%   char key[key_len];
%   char value[header.msg_size-2-key_len]
% };

is_continued = fds.log_data(fds.idx); ...
    fds.idx = fds.idx + 1;
key_len = double(fds.log_data(fds.idx)); ...
    fds.idx = fds.idx + 1;
key = char(fds.log_data(fds.idx:fds.idx+key_len-1)); ...
    fds.idx = fds.idx + key_len;

[~,msg_name] = strtok(key);

% Sanitise msg_name string
if strcmp(msg_name(1),' '); msg_name(1) = []; end
if strcmp(msg_name(1),'_'); msg_name(1) = []; end

msg_len = sscanf(key, '%*[^[][%d]');

msg = fds.log_data(fds.idx:fds.idx+msg_len-1); ...
    fds.idx = fds.idx + msg_len;

% Store the message
if ~isfield(fds.perf_msgs,msg_name)
    fprintf('\tAdding message name %s\n',msg_name);
    try
        fds.perf_msgs.(msg_name) = {};
    catch
        keyboard
        return
    end
end

% Store the message
if (is_continued)
    % Check if the message contains a \n.  If so, append
    % previous message and start a new one.  If not, just make
    % a new message line as it is probably a self-contained
    % message
    if isempty(find(msg==10, 1))
        % Doesn't contain any line breaks (\n), probably just create
        % a new line here
        fds.perf_msgs.(msg_name){end+1,1} = char(msg);
    else
        % Message contains line breaks, let's break them up for
        % ease of reading later
        loc = find(msg==10, 1);
        while (loc == 1) && (~isempty(loc))
            msg = msg(2:end);
            loc = find(msg==10, 1);
        end
        
        while ~isempty(loc)
            % If the array doesn't exist, create one to add the
            % message in to
            if isempty(fds.perf_msgs.(msg_name))
                fds.perf_msgs.(msg_name){1} = [];
            end
            
            % Add the message
            fds.perf_msgs.(msg_name){end} = [fds.perf_msgs.(msg_name){end},char(msg(1:loc-1))];
            
            if loc ~= numel(msg)
                fds.perf_msgs.(msg_name){end+1,1} = [];
            end
            
            % Remove the part we just stored
            msg = msg(loc+1:end);
            loc = find(msg==10, 1);
        end
        
        % Add the last bit to a new message
        fds.perf_msgs.(msg_name){end+1,1} = char(msg);
    end
    
else
    % Create a new message line
    fds.perf_msgs.(msg_name){end+1,1} = char(msg);
end

% Debugging
% fprintf('\t%s (%s)\n',msg_name,msg_type);
% fprintf('\t\t%s\n',msg);

return
end

function fds = add_logged_message(fds,msg_size)
% struct message_add_logged_s {
%   struct message_header_s header;
%   uint8_t multi_id;
%   uint16_t msg_id;
%   char message_name[header.msg_size-3];
% };

% We need this data to we know how to decode each of the logs
% (based on their msg_id).

multi_id = fds.log_data(fds.idx); ...
    fds.idx = fds.idx + 1;
msg_id = typecast(fds.log_data(fds.idx:fds.idx+1),'uint16'); ...
    fds.idx = fds.idx + 2;
message_name = char(fds.log_data(fds.idx:fds.idx+msg_size-4)); ...
    fds.idx = fds.idx + msg_size - 3;

message_name = genvarname([message_name,'_',num2str(multi_id,'%d')]);

log_idx = ['log_',num2str(msg_id,'%03d')];

% Store definitition for later
if ~isfield(fds.log_msg_locs,log_idx)
    %fprintf('\tAdding log %s as %s\n',message_name,log_idx);
    fds.log_msg_locs.(log_idx) = struct();
    
    % Work out which type of log it belongs to
    log_type = message_name(1:end-2);
    
    fds.log_msg_locs.(log_idx).log_name = message_name;
    fds.log_msg_locs.(log_idx).msg_id   = msg_id;
    fds.log_msg_locs.(log_idx).multi_id = multi_id;
    fds.log_msg_locs.(log_idx).log_type = log_type;
    fds.log_msg_locs.(log_idx).msg_size = 153;  % More likely to false positive on 0 than 153
    
end

% Debugging
%  fprintf('\tAdd Log - %s (%d)\n',message_name,msg_id);

return
end

function fds = logged_data_message(fds,msg_size)
% struct message_data_s {
%   struct message_header_s header;
%   uint16_t msg_id;
%   uint8_t data[header.msg_size-2];
% };

% Realistically we probably only want to store the location of
% the logged message (and the type), then go back through
% later, loop through all the message types and then extract
% the data.  That way we're not making massive matricies of
% unknown size.  As such, we only need to know the log name, id
% and type at this point in time (plus the locs where we've seen
% it.
fds.idx = fds.idx + msg_size;
return
end

function fds = string_message(fds,msg_size)
% struct message_logging_s {
%   struct message_header_s header;
%   uint8_t log_level;
%   uint64_t timestamp;
%   char message[header.msg_size-9]
% };

log_level = fds.log_data(fds.idx); ...
    fds.idx = fds.idx + 1;
timestamp = typecast(fds.log_data(fds.idx:fds.idx+7),'uint64'); ...
    fds.idx = fds.idx + 8;
len_message = msg_size - 9;
message = char(fds.log_data(fds.idx:fds.idx+len_message-1)); ...
    fds.idx = fds.idx + len_message;

% Create the structure
if isempty(fieldnames(fds.messages))
    fds.messages.timestamp = [];
    fds.messages.log_level = [];
    fds.messages.message   = {};
end

% Store the information
fds.messages.timestamp(end+1,1) = timestamp;
fds.messages.log_level(end+1,1) = log_level;
fds.messages.message{end+1,1}   = message;

return
end

function fds = sync_message(fds,msg_size)
% struct message_sync_s {
%   struct message_header_s header;
%   uint8_t sync_magic[8];
% };
sync_string = fds.log_data(fds.idx:fds.idx+7);
sync_magic =  uint8([47,115,19,32,37,12,187,18]);

fds.idx = fds.idx + msg_size;


return;

end

function fds = extract_data(fds,log_id)
log_name = fds.log_msg_locs.(log_id).log_name;
log_type = fds.log_msg_locs.(log_id).log_type;

type_def = fds.log_msg_def.(log_type);

% Find the locs that we're after
% struct message_header_s header;
%    (uint16_t) size
%    (char)     type     (D)
%    (uint16_t) msg_id;

% Get the message size
msg_size = fds.log_msg_size.(log_type)+2;  % Adding the header size


if isnan(msg_size)
    % We should have already expanded all this out
    % Keyboard here to work out what is wrong
    keyboard
    return;
end

header = [ typecast(uint16(msg_size),'uint8'), uint8('D'), typecast(fds.log_msg_locs.(log_id).msg_id,'uint8')];

locs = strfind(fds.log_data, header)' + 5; ...
    n_samples = numel(locs);

% Extract the data
if n_samples > 0
    % Create the struct to hold the data
    fprintf('\t\t%s\n', log_name);
    fprintf('\t\t\t%5d samples\n',n_samples);
    fds.logs.(log_name) = struct;
    fields = fieldnames(type_def); ...
        n_fields = numel(fields);
    
    data_types = cell(numel(fields),1);
    for ii = 1:numel(fields)
        field = fields{ii};
        data_types{ii} = fds.log_msg_def.(log_type).(field);
        
    end
    
    % Create a matrix to store all the data.  We'll then break
    % it up into it's appropriate struct fields at the end.
    % Might be a bit faster...
    data = nan(n_samples,n_fields);
    
    % Extract the data into the struct by looping through each
    % field type (faster than doing it by sample)
    loc_offset = 0;
    
    for jj = 1:n_fields
        data_type = data_types{jj};
        n_bytes    = getVarSize(data_type);
        
        % Read and cast appropriate number of things
        switch (data_type)
            case 'bool'
                tempLocs   = locs+loc_offset;
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),1)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/1)*1);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'uint8')';
                loc_offset = loc_offset + n_bytes;
                
            case 'uint8_t'
                tempLocs   = locs+loc_offset;
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),1)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/1)*1);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'uint8')';
                loc_offset = loc_offset + n_bytes;
                
            case 'int8_t'
                tempLocs   = locs+loc_offset;
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),1)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/1)*1);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'int8')';
                loc_offset = loc_offset + n_bytes;
                
            case 'uint16_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),2)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/2)*2);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'uint16')';
                loc_offset = loc_offset + n_bytes;
                
            case 'int16_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),2)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/2)*2);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'int16')';
                loc_offset = loc_offset + n_bytes;
                
            case 'uint32_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),4)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/4)*4);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'uint32')';
                loc_offset = loc_offset + n_bytes;
                
            case 'int32_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),4)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/4)*4);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'int32')';
                loc_offset = loc_offset + n_bytes;
                
            case 'uint64_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),8)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/8)*8);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'uint64')';
                loc_offset = loc_offset + n_bytes;
                
            case 'int64_t'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),8)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/8)*8);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'int64')';
                loc_offset = loc_offset + n_bytes;
                
            case 'float'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),4)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/4)*4);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'single')';
                loc_offset = loc_offset + n_bytes;
                
            case 'double'
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                % Handle if log cut off mis-message
                tempLocs(tempLocs > size(fds.log_data,2)) = [];
                if rem(size(tempLocs,2),8)
                    tempLocs = tempLocs(1:floor(size(tempLocs,2)/8)*8);
                end
                % Extract data
                new_data   = typecast(fds.log_data(tempLocs),'double')';
                loc_offset = loc_offset + n_bytes;
            
            case 'char'
                continue
                tempLocs   = reshape((locs + (0:n_bytes-1))'+loc_offset,1,[]);
                new_data   = typecast(fds.log_data(tempLocs),'char')';
                loc_offset = loc_offset + n_bytes;                
                
            otherwise
                fprintf('Unrecognised data type\n');
                fprintf('\t%s - %s\n',field, data_type);
                % do nothing
                keyboard
                
        end
        
        % Add this field's data to the main struct's data
        % matrix
        if size(new_data,1) ~= size(data,1)
            new_data = [new_data;nan];
%             keyboard
        end
        data(:,jj) = new_data;
        
    end
    
    % Extract the data back out into the struct format
    for ii = 1:n_fields
        field = fields{ii};
        fds.logs.(log_name).(field) = data(:,ii);
    end
end

return

end

function n_bytes = getVarSize(varType)
% Script for returning the size of different variable types

switch (varType)
    case 'bool';     n_bytes = 1;
    case 'char';     n_bytes = 1;
    case 'uint8_t';  n_bytes = 1;
    case 'int8_t';   n_bytes = 1;
    case 'uint16_t'; n_bytes = 2;
    case 'int16_t';  n_bytes = 2;
    case 'uint32_t'; n_bytes = 4;
    case 'int32_t';  n_bytes = 4;
    case 'uint64_t'; n_bytes = 8;
    case 'int64_t';  n_bytes = 8;
    case 'float';    n_bytes = 4;
    case 'double';   n_bytes = 8;
    otherwise
        % do nothing
        %fprintf('Unrecognised data type - %s\n',varType);
        n_bytes = nan;
        
end

return;

end

function data = remove_padding_fields(data)
% Removes the padding terms from the generated structs

logs = fieldnames(data.logs);

for ii = 1:numel(logs)
    log = logs{ii};
    channels = fieldnames(data.logs.(log));
    
    for jj = 1:numel(channels)
        channel = channels{jj};
        
        if contains(channel,'padding0')
            data.logs.(log) = rmfield(data.logs.(log),channel);
            
        end
    end
end

% The data struct should now have all the padding removed

return
end

function make_check_plots(fds)
% Plot all the imported data
% Useful as a check to make sure things imported well
fields = fieldnames(fds.logs);

for ii = 1:numel(fields)
    % Dataset 1
    field_struct = fds.logs.(fields{ii});
    channels = fieldnames(field_struct);
    num_channels = numel(channels);
    plot_h = ceil(sqrt(num_channels));
    plot_w = ceil((num_channels)/plot_h);
    t = field_struct.(channels{1})/1e6;
    
    % Plots
    figure(ii); clf; set(gcf,'name',fields{ii});
    set(gcf,'units','normalized');
    set(gcf,'outerposition',[0 0 1 1]);
    for jj = 2:num_channels
        subplot(plot_h,plot_w,jj-1); hold all; ...
            plot(t,field_struct.(channels{jj})); ...
            title(channels{jj},'interpreter','none');
    end
    
end

return
end


