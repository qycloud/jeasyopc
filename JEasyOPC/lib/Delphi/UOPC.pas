unit UOPC;

interface

uses
  Classes, SysUtils, Windows, ActiveX, JNI, UCustomOPC, OPCUtils, UOPCGroup, UOPCItem,
  OPCTypes, UOPCAsynch, UOPCExceptions;

type

  TOPC = class(TCustomOPC)
  private
    groups : TList;
    FDownOPCGroup : EVENT_DownOPCGroup; // download group event (asynchronous mode)
    // implementation of EVENT_OPCItem
    procedure DownloadedItems(cHandle_Group, cHandle_Item : OPCHANDLE; Quality : Word;
      IType : Word; DTime : TDateTime; Value : string);
    // implementation of EVENT_OPCGroup
    procedure DownloadedGroup(cHandle_Group : OPCHANDLE);
  public
    // constructor (override)
    constructor create(host, ServerProgID, ServerClientHandle : string);
    // add group
    procedure addGroup(group : TOPCGroup);
    // remove group
    function  removeGroup(group : TOPCGroup) : TOPCGroup;
    // get count of groups
    function getGroupCount : integer;
    // get group by clientHandle
    function getGroupByClientHandle(clientHandle : OPCHANDLE) : TOPCGroup;
    // get group by Java object
    function getGroupByJavaCode(PEnv: PJNIEnv; group: JObject) : TOPCGroup;
    //************************************************
    // register group to server, throws UnableAddGroupException
    procedure registerGroup(group : TOPCGroup);
    // register item in specific group, throws UnableAddItemException
    procedure registerItem(group : TOPCGroup; item : TOPCItem); overload;
    // register all groups with items to server,
    // throws UnableAddGroupException, UnableAddItemException
    procedure registerGroups;
    // unregister group, throws UnableRemoveGroupException
    procedure unregisterGroup(group : TOPCGroup);
    // unregister all groups, throws UnableRemoveGroupException
    procedure unregisterGroups;
    // unregister item
    procedure unregisterItem(group : TOPCGroup; item : TOPCItem);
    //************************************************
    // update groups from JAVA
    procedure updateGroups(PEnv: PJNIEnv; Obj: JObject);
    // store structure of opc to file
    procedure storeStructureToFile(fn : string);
    //************************************************
    // read item (Synch), throws ComponentNotFoundException, SynchReadException
    function synchReadItem(PEnv: PJNIEnv; group: JObject; item: JObject) : JObject;
    // write item (Synch)
    procedure synchWriteItem(PEnv: PJNIEnv; group: JObject; item: JObject);
  published
    //EVENT: get actual groups from OPC
    property OnDownloadedGroup: EVENT_DownOPCgroup read FDownOPCGroup write FDownOPCGroup;
  end;

implementation

{ TOPC }

constructor TOPC.create(host, ServerProgID, ServerClientHandle: string);
begin
  inherited create(host, ServerProgID, ServerClientHandle);
  groups := TList.create;
end;

//------------------------------------------------------------------------------

procedure TOPC.addGroup(group: TOPCGroup);
begin
  groups.add(group);
end;

//------------------------------------------------------------------------------

function TOPC.removeGroup(group : TOPCGroup): TOPCGroup;
var i : integer;
begin
  for i:=0 to groups.count-1 do
    if groups[i] = group
    then begin
      Result := groups[i];
      groups.delete(i);
      exit;
    end;
  Result := nil;
end;

//------------------------------------------------------------------------------

function TOPC.getGroupByClientHandle(clientHandle: OPCHANDLE): TOPCGroup;
var i : integer;
begin
  for i:=0 to groups.count-1 do
    if TOPCGroup(groups[i]).getClientHandle = clientHandle
    then begin
      Result := groups[i];
      exit;
    end;
  Result := nil;
end;

//------------------------------------------------------------------------------

function TOPC.getGroupByJavaCode(PEnv: PJNIEnv; group: JObject): TOPCGroup;
var
  JVM         : TJNIEnv;
  FID         : JFieldID;
  groupClass  : JClass;
  gch         : integer;
  groupNative : TOPCGroup;
begin
  JVM := TJNIEnv.Create(PEnv);

  // get classes
  groupClass := JVM.GetObjectClass(group);

  // get clientHandles
  FID := JVM.GetFieldID(groupClass, 'clientHandle', 'I');
  gch := JVM.GetIntField(group, FID);

  JVM.Free;

  // get native objects
  groupNative := getGroupByClientHandle(gch);

  if groupNative = nil
  then raise ComponentNotFoundException.create(ComponentNotFoundExceptionText)
  else Result := groupNative;
end;

//------------------------------------------------------------------------------

function TOPC.getGroupCount: integer;
begin
  Result := groups.count;
end;

//------------------------------------------------------------------------------

procedure TOPC.registerGroup(group: TOPCGroup);
begin
  // use wrapper
  HR := ServerAddGroup(ServerIf, group.getGroupName, group.isActive, group.getUpdateRate,
    group.getClientHandle, group.getPercentDeadBand, group.GroupIf, group.GroupHandle);
  if not Succeeded(HR)
  then raise UnableAddGroupException.create(group.getGroupName);
end;

//------------------------------------------------------------------------------

procedure TOPC.registerGroups;
var i, j  : integer;
    items : TList;
    group : TOPCGroup;
    item  : TOPCItem;
begin
  // register groups
  for i:=0 to groups.count-1 do
  begin
    group := TOPCGroup(groups[i]);
    registerGroup(group);
    items := group.getItems;
    // register items in group
    for j:=0 to items.count-1 do
    begin
      item := TOPCItem(items[j]);
      registerItem(group, item);
    end;
  end;
end;

//------------------------------------------------------------------------------

procedure TOPC.registerItem(group : TOPCGroup; item : TOPCItem);
begin
  HR := GroupAddItem(group.GroupIf, item.getItemName, item.getClientHandle,
    VT_EMPTY, item.isActive, item.getAccessPath,
    item.ItemHandle, item.ItemType); //item.getDataType
  if not Succeeded(HR)
  then raise UnableAddItemException.create(item.getItemName);
end;

//------------------------------------------------------------------------------

procedure TOPC.unregisterGroup(group: TOPCGroup);
begin
  HR := ServerIf.RemoveGroup(group.GroupHandle, False);
  if not Succeeded(HR)
  then raise UnableRemoveGroupException.create(group.getGroupName);
end;

//------------------------------------------------------------------------------

procedure TOPC.unregisterGroups;
var i : integer;
begin
  for i:=0 to groups.count-1 do
    unregisterGroup(groups[i]);
end;

//------------------------------------------------------------------------------

procedure TOPC.unregisterItem(group: TOPCGroup; item: TOPCItem);
begin
  HR := GroupRemoveItem(group.GroupIf, item.ItemHandle);
  if not Succeeded(HR)
  then raise UnableRemoveItemException.create(item.getItemName);
end;

//------------------------------------------------------------------------------

procedure TOPC.updateGroups(PEnv: PJNIEnv; Obj: JObject);
var
  getGroupsAsArray : JMethodID;
  JVM          : TJNIEnv;
  Cls          : JClass;
  FID          : JFieldID;
  agroups      : JArray;
  group        : JObject;
  groupNative  : TOPCGroup;
  groupClass   : JClass;
  groupsCount  : integer;
  i            : integer;
  j            : integer;
  groupCHandle : integer;
  cha          : array of integer;
  exists       : boolean;
begin
  JVM := TJNIEnv.Create(PEnv);

  // update groups
  Cls := JVM.GetObjectClass(Obj);

  // get group from groups map by its clientHandle
  getGroupsAsArray := JVM.GetMethodID(Cls, 'getGroupsAsArray',
    '()[Ljavafish/clients/opc/component/OPCGroup;');
  agroups := JArray(JVM.CallObjectMethodA(Obj, getGroupsAsArray, nil));

  groupsCount := JVM.GetArrayLength(agroups);
  setLength(cha, groupsCount);

  for i:=0 to groupsCount-1 do
  begin
    // get group from Java
    group := JVM.GetObjectArrayElement(agroups, i);

    // attribute: clientHandle
    groupClass := JVM.GetObjectClass(group);
    FID := JVM.GetFieldID(groupClass, 'clientHandle', 'I');
    groupCHandle := JVM.GetIntField(group, FID);
    cha[i] := groupCHandle; // set to memory

    groupNative := getGroupByClientHandle(groupCHandle);
    if groupNative <> nil
    then groupNative.update(PEnv, group) // update group
    else addGroup(TOPCGroup.create(PEnv, group)); // create new group
  end;

  // delete items
  i:=0;
  while i <= getGroupCount-1 do
  begin
    exists := false;
    for j:=Low(cha) to High(cha) do
      if cha[j] = TOPCGroup(Groups[i]).getClientHandle
      then begin
        exists := true;
        break;
      end;
    if not exists
    then removeGroup(Groups[i])
    else i := i + 1;
  end;

  JVM.Free;
end;

//------------------------------------------------------------------------------

procedure TOPC.storeStructureToFile(fn: string);
var foo   : TStringList;
    i,j   : integer;
    group : TOPCGroup;
    item  : TOPCItem;
    items : TList;
begin
  foo := TStringList.Create;
  for i:=0 to getGroupCount-1 do
  begin
    group := TOPCGroup(Groups[i]);
    foo.Add('GROUP: ' + group.getGroupName);
    foo.Add('GROUP clientHandle: ' + IntToStr(group.getClientHandle));
    foo.Add('GROUP updateRate: ' + IntToStr(group.getUpdateRate));
    foo.Add('GROUP active: ' + BoolToStr(group.isActive, true));
    foo.Add('GROUP percentDeadBand: ' + FloatToStr(group.getPercentDeadBand));

    items := group.getItems;
    if items <> nil
    then begin
      if items.Count > 0
      then begin
        for j:=0 to items.Count-1 do
        begin
          item := TOPCItem(items[j]);
          foo.Add('GROUP.Item: ' + item.getItemName);
          foo.Add('GROUP.Item clientHandle: ' + IntToStr(item.getClientHandle));
          foo.Add('GROUP.Item accessPath: ' + item.getAccessPath);
          foo.Add('GROUP.Item itemValue: ' + item.getItemValue);
          foo.Add('GROUP.Item active: ' + BoolToStr(item.isActive, true));
          foo.Add('GROUP.Item dataType: ' + IntToStr(item.getDataType));
          //foo.Add('GROUP.Item quality: ' + BoolToStr(item.getItemQuality, true));
        end;
      end else foo.Add('ITEMS: empty group');
    end
    else foo.Add('ITEMS: empty group');
  end;
  // store to file
  foo.SaveToFile(fn);
  foo.Free;
end;

//------------------------------------------------------------------------------

function TOPC.synchReadItem(PEnv: PJNIEnv; group, item: JObject): JObject;
var
  groupNative : TOPCGroup;
  itemNative  : TOPCItem;
  value       : string;
  quality     : word;
  itm         : JObject;
begin
  groupNative := getGroupByJavaCode(PEnv, group);
  itemNative  := groupNative.getItemByJavaCode(PEnv, item);

  HR := ReadOPCGroupItemValue(groupNative.GroupIf, itemNative.ItemHandle, value, quality);
  if Succeeded(HR)
  then begin
    itemNative.setTimeStamp(Now); // set actual timeStamp (System time)
    itemNative.setItemValue(value);
    itemNative.setItemQuality(quality);
    itm := itemNative.clone(PEnv, item);
    itemNative.commit(PEnv, itm);
    Result := itm;
  end
  else raise SynchReadException.create(SynchReadExceptionText);
end;

//------------------------------------------------------------------------------

procedure TOPC.synchWriteItem(PEnv: PJNIEnv; group, item: JObject);
var
  groupNative : TOPCGroup;
  itemNative  : TOPCItem;
begin
  groupNative := getGroupByJavaCode(PEnv, group);
  itemNative  := groupNative.getItemByJavaCode(PEnv, item);
  itemNative.update(PEnv, item); // set write parameters

  HR := WriteOPCGroupItemValue(groupNative.GroupIf, itemNative.ItemHandle, itemNative.getItemValue);
  if not Succeeded(HR)
  then raise SynchWriteException.create(SynchWriteExceptionText);
end;

//------------------------------------------------------------------------------
// asynch event implementation
procedure TOPC.DownloadedGroup(cHandle_Group: OPCHANDLE);
begin
  // call user event for downloaded cHandle_Group
  if Assigned(OnDownloadedGroup)
  then FDownOPCGroup(cHandle_Group, getGroupByClientHandle(cHandle_Group));
end;

//------------------------------------------------------------------------------
// asynch event implementation
procedure TOPC.DownloadedItems(cHandle_Group, cHandle_Item: OPCHANDLE; Quality,
  IType: Word; DTime: TDateTime; Value: string);
var item : TOPCItem;
begin
  // set data to item
  item := getGroupByClientHandle(cHandle_Group).getItemByClientHandle(cHandle_Item);
  if item <> nil
  then begin
    item.setItemQuality(Quality);
    item.setItemType(IType);
    item.setTimeStamp(DTime);
    item.setItemValue(value);
  end;
end;

//------------------------------------------------------------------------------

end.
