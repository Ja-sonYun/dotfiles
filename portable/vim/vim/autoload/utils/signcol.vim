vim9script

export class Spec
  var kind: string
  var text: string = ''
  var texthl: string = ''
  var numhl: string = ''
  var linehl: string = ''

  def Definition(): dict<any>
    var definition: dict<any> = {}
    if this.text !=# ''
      definition.text = this.text
    endif
    if this.texthl !=# ''
      definition.texthl = this.texthl
    endif
    if this.numhl !=# ''
      definition.numhl = this.numhl
    endif
    if this.linehl !=# ''
      definition.linehl = this.linehl
    endif
    return definition
  enddef

  def Signature(): list<any>
    return [this.kind, this.text, this.texthl, this.numhl, this.linehl]
  enddef

  def Define(group: string): void
    sign_define(group .. '_' .. this.kind, this.Definition())
  enddef
endclass

export class Item
  var kind: string
  var lnum: number
  var key: string = ''

  def Key(): string
    if this.key ==# ''
      this.key = this.kind .. '@' .. string(this.lnum)
    endif
    return this.key
  enddef
endclass

class Placed
  var id: number
  public var lnum: number
  public var kind: string

  def new(this.id, this.lnum, this.kind)
  enddef

  def Unplace(group: string, buf: number): void
    sign_unplace(group, { buffer: buf, id: this.id })
  enddef

  def Matches(kind: string, lnum: number): bool
    return this.kind ==# kind && this.lnum == lnum
  enddef
endclass

class State
  public var placed: dict<Placed> = {}

  def Clear(group: string, buf: number): void
    if empty(this.placed)
      return
    endif
    sign_unplace(group, { buffer: buf })
    this.placed = {}
  enddef
endclass

export class SignCol
  static var spec_hash: dict<string> = {}

  public var group: string
  public var kinds: dict<Spec> = {}
  public var state: dict<State> = {}

  def new(this.group, specs: list<Spec>)
    this.AssertSignApi()
    for spec in specs
      this.kinds[spec.kind] = spec
    endfor
    this.DefineKindsIfChanged()
  enddef

  def AssertSignApi(): void
    var missing: list<string> = []
    if !exists('*sign_define')
      add(missing, 'sign_define')
    endif
    if !exists('*sign_placelist')
      add(missing, 'sign_placelist')
    endif
    if !exists('*sign_unplace')
      add(missing, 'sign_unplace')
    endif
    if !exists('*sign_getplaced')
      add(missing, 'sign_getplaced')
    endif
    if !empty(missing)
      throw 'signcol: missing sign functions: ' .. join(missing, ', ')
    endif
  enddef

  def NameFor(kind: string): string
    return this.group .. '_' .. kind
  enddef

  def DefineKindsIfChanged(): void
    var signatures: list<list<any>> = []
    for spec in values(this.kinds)
      add(signatures, spec.Signature())
    endfor
    var signatureText = string(signatures)
    var hash = sha256(signatureText)
    if get(SignCol.spec_hash, this.group, '') ==# hash
      return
    endif
    for spec in values(this.kinds)
      spec.Define(this.group)
    endfor
    SignCol.spec_hash[this.group] = hash
  enddef

  def GetState(buf: number): State
    var bufferKey = string(buf)
    if has_key(this.state, bufferKey)
      return this.state[bufferKey]
    endif
    var state = State.new()
    this.state[bufferKey] = state
    return state
  enddef

  def BufferLineCount(buf: number): number
    if !bufexists(buf)
      return 0
    endif
    var info = get(getbufinfo(buf), 0, {})
    return get(info, 'linecount', 0)
  enddef

  def ClampLnum(maxLine: number, lineNumber: number): number
    if maxLine <= 0
      return lineNumber
    endif
    if lineNumber < 1
      return 1
    endif
    if lineNumber > maxLine
      return maxLine
    endif
    return lineNumber
  enddef

  def BuildWanted(entries: list<Item>, maxLine: number): dict<dict<any>>
    var wanted: dict<dict<any>> = {}
    for entry in entries
      if type(entry) != v:t_object
        continue
      endif
      if !has_key(this.kinds, entry.kind)
        continue
      endif
      var clamped = this.ClampLnum(maxLine, entry.lnum)
      wanted[entry.Key()] = { kind: entry.kind, lnum: clamped }
    endfor
    return wanted
  enddef

  def KeepExisting(wanted: dict<dict<any>>, placed: dict<Placed>): dict<number>
    var keepIds: dict<number> = {}
    for [key, placedSign] in items(placed)
      if !has_key(wanted, key)
        continue
      endif
      var target = wanted[key]
      if placedSign.Matches(target.kind, target.lnum)
        keepIds[placedSign.id] = 1
        remove(wanted, key)
      endif
    endfor
    return keepIds
  enddef

  def FetchPlacedSigns(buf: number): list<dict<any>>
    var placedInfo = sign_getplaced(buf, { group: this.group })
    if empty(placedInfo) || !has_key(placedInfo[0], 'signs')
      return []
    endif
    return placedInfo[0].signs
  enddef

  def UnplaceRemoved(buf: number, keepIds: dict<number>, signs: list<dict<any>>): void
    for sign in signs
      var signId = get(sign, 'id', 0)
      if signId > 0 && !has_key(keepIds, signId)
        sign_unplace(this.group, { buffer: buf, id: signId })
      endif
    endfor
  enddef

  def FindSignLnum(signs: list<dict<any>>, signId: number, fallback: number): number
    for sign in signs
      if get(sign, 'id', 0) == signId
        return get(sign, 'lnum', fallback)
      endif
    endfor
    return fallback
  enddef

  def SyncPlaced(placed: dict<Placed>, signs: list<dict<any>>): dict<Placed>
    if empty(signs)
      return {}
    endif
    var liveIds: dict<number> = {}
    for sign in signs
      var signId = get(sign, 'id', 0)
      if signId > 0
        liveIds[signId] = 1
      endif
    endfor
    for [key, placedSign] in items(placed)
      if !has_key(liveIds, placedSign.id)
        remove(placed, key)
      else
        placedSign.lnum = this.FindSignLnum(signs, placedSign.id, placedSign.lnum)
      endif
    endfor
    return placed
  enddef

  def PlaceWanted(buf: number, wanted: dict<dict<any>>, placed: dict<Placed>): dict<Placed>
    if empty(wanted)
      return placed
    endif
    var addList: list<dict<any>> = []
    var addKeys: list<string> = []
    for [key, value] in items(wanted)
      add(addList, {
        buffer: buf,
        group: this.group,
        id: 0,
        name: this.NameFor(value.kind),
        lnum: value.lnum,
      })
      add(addKeys, key)
    endfor
    var ids: list<number> = sign_placelist(addList)
    for index in range(0, len(ids) - 1)
      var newId = ids[index]
      if newId > 0
        var addKey = addKeys[index]
        var signName = addList[index].name
        var signKind = substitute(signName, '^' .. this.group .. '_', '', '')
        placed[addKey] = Placed.new(newId, addList[index].lnum, signKind)
      endif
    endfor
    return placed
  enddef

  def Update(buf: number, entries: list<Item>): void
    if buf <= 0
      return
    endif

    var maxLine = this.BufferLineCount(buf)
    if maxLine <= 0
      return
    endif

    var bufferKey = string(buf)
    var state = this.GetState(buf)
    var placed = state.placed

    var wanted = this.BuildWanted(entries, maxLine)
    var keepIds = this.KeepExisting(wanted, placed)

    var signs = this.FetchPlacedSigns(buf)
    this.UnplaceRemoved(buf, keepIds, signs)
    signs = this.FetchPlacedSigns(buf)

    placed = this.SyncPlaced(placed, signs)
    placed = this.PlaceWanted(buf, wanted, placed)

    state.placed = placed
    this.state[bufferKey] = state
  enddef


  def Clear(buf: number): void
    var bufferKey = string(buf)
    if has_key(this.state, bufferKey)
      this.state[bufferKey].Clear(this.group, buf)
    endif
  enddef

  def ClearAll(): void
    for [bufferKey, state] in items(this.state)
      state.Clear(this.group, str2nr(bufferKey))
    endfor
  enddef

  def Status(buf: number): dict<any>
    var count = 0
    var bufferKey = string(buf)
    if has_key(this.state, bufferKey)
      count = len(keys(this.state[bufferKey].placed))
    endif
    return { buffer: buf, placed: count, group: this.group }
  enddef
endclass
