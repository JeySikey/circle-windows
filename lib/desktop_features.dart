import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'api.dart';
import 'design.dart';
import 'live_room.dart';

// Native desktop tools. No WebView or browser sessions: all calls use bearer API.
Map<String, dynamic> fxMap(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : {};
List<Map<String, dynamic>> fxRows(dynamic v) => v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
int fxId(dynamic v) => int.tryParse('$v') ?? 0;
void fxNotice(BuildContext context, Object value) {if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$value')));}
Future<String?> fxPrompt(BuildContext context, String title, {String initial='', bool secret=false, int lines=1}) async {
  final c=TextEditingController(text: initial);
  try {
    return await showDialog<String>(context: context, builder: (dialog) => AlertDialog(
      title: Text(title), content: SizedBox(width: 390, child: TextField(controller: c, obscureText: secret,
        minLines: secret ? 1 : lines, maxLines: secret ? 1 : lines, autofocus: true, decoration: const InputDecoration(hintText: 'Введите значение'))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(dialog,c.text.trim()), child: const Text('Сохранить'))]));
  } finally {c.dispose();}
}
Future<bool> fxConfirm(BuildContext context, String title, String description) async => await showDialog<bool>(context: context,
  builder: (dialog) => AlertDialog(title: Text(title), content: Text(description), actions: [TextButton(onPressed: () => Navigator.pop(dialog,false), child: const Text('Отмена')),
    FilledButton(onPressed: () => Navigator.pop(dialog,true), child: const Text('Подтвердить'))])) ?? false;

class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.title, required this.child, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1120),
      child: Column(children: [if(subtitle!=null) Padding(padding: const EdgeInsets.fromLTRB(20,16,20,6),
        child: Align(alignment: Alignment.centerLeft, child: Text(subtitle!, style: Theme.of(context).textTheme.bodySmall))),
        Expanded(child: child)]))));
}

class DesktopSecurityScreen extends StatefulWidget {
  const DesktopSecurityScreen(this.api,{super.key});
  final CircleApi api;
  @override State<DesktopSecurityScreen> createState()=>_DesktopSecurityScreenState();
}
class _DesktopSecurityScreenState extends State<DesktopSecurityScreen>{
  late Future<Map<String,dynamic>> state;
  @override void initState(){super.initState(); refresh();}
  void refresh(){state=widget.api.call('desktop-security');}
  Future<void> changePassword() async{
    final current=await fxPrompt(context,'Текущий пароль',secret:true);if(!mounted||current==null)return;
    final next=await fxPrompt(context,'Новый пароль (от 10 символов)',secret:true);if(!mounted||next==null)return;
    final again=await fxPrompt(context,'Повторите новый пароль',secret:true);if(!mounted||again==null)return;
    if(next!=again){fxNotice(context,'Новые пароли не совпадают');return;}
    try{await widget.api.call('desktop-password-change',body:{'current_password':current,'new_password':next});if(mounted)fxNotice(context,'Пароль изменён. Другие сессии отключены.');}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> changeUsername() async{
    final username=await fxPrompt(context,'Новый логин (латиница, цифры, _)',initial:'');if(!mounted||username==null)return;
    final password=await fxPrompt(context,'Подтвердите действующим паролем',secret:true);if(!mounted||password==null)return;
    try{await widget.api.call('desktop-username-change',body:{'username':username,'password':password});if(mounted){setState(refresh);fxNotice(context,'Логин обновлён');}}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> revoke(int id,String kind) async{
    if(!await fxConfirm(context,'Завершить сеанс?','Выбранное устройство потеряет доступ к аккаунту.'))return;
    try{await widget.api.call('desktop-device-revoke',body:{'id':id,'kind':kind});if(mounted)setState(refresh);}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> enableTotp() async {
    final password=await fxPrompt(context,'Текущий пароль',secret:true);if(!mounted||password==null)return;
    try{
      final challenge=await widget.api.call('desktop-totp-start',body:{'password':password});if(!mounted)return;
      final secret='${challenge['secret'] ?? ''}';final token='${challenge['challenge'] ?? ''}';
      final code=await showDialog<String>(context:context,builder:(dialog){final input=TextEditingController();return AlertDialog(
        title:const Text('Подключить двухфакторную защиту'),
        content:SizedBox(width:470,child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Добавь секрет в приложение-аутентификатор, затем введи шестизначный код. Секрет действует 10 минут.'),
          const SizedBox(height:12),SelectableText(secret,style:const TextStyle(color:circleGoldBright,fontWeight:FontWeight.w700)),
          const SizedBox(height:16),TextField(controller:input,keyboardType:TextInputType.number,maxLength:6,decoration:const InputDecoration(labelText:'Код подтверждения'))])),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Отмена')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,input.text.trim()),child:const Text('Включить'))]);});
      if(!mounted||code==null)return;
      final r=await widget.api.call('desktop-totp-enable',body:{'challenge':token,'code':code});if(!mounted)return;
      final recovery=(r['recovery_codes'] as List? ?? []).join('   ');
      await showDialog<void>(context:context,barrierDismissible:false,builder:(dialog)=>AlertDialog(title:const Text('Резервные коды — сохрани сейчас'),
        content:SizedBox(width:470,child:SelectableText(recovery)),actions:[TextButton(onPressed:(){Clipboard.setData(ClipboardData(text:recovery));},child:const Text('Копировать')),FilledButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Я сохранил коды'))]));
      if(mounted)setState(refresh);
    }catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> disableTotp() async {
    final password=await fxPrompt(context,'Пароль для отключения 2FA',secret:true);if(!mounted||password==null)return;
    final code=await fxPrompt(context,'Код из приложения-аутентификатора');if(!mounted||code==null)return;
    try{await widget.api.call('desktop-totp-disable',body:{'password':password,'code':code});if(mounted)setState(refresh);}catch(e){if(mounted)fxNotice(context,e);}
  }
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Безопасность аккаунта',subtitle:'Устройства, пароль и управление доступом',
    child: FutureBuilder<Map<String,dynamic>>(future:state,builder:(context,s){
      if(s.hasError)return CircleEmpty(title:'Не удалось загрузить безопасность',description:'${s.error}',action:TextButton(onPressed:()=>setState(refresh),child:const Text('Повторить')));
      if(!s.hasData)return const Center(child:CircularProgressIndicator());
      final account=fxMap(s.data!['account']);final sessions=fxRows(s.data!['sessions']);final devices=fxRows(s.data!['devices']);
      return ListView(padding:const EdgeInsets.all(20),children:[
        CircleSurface(accent:true,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const CircleSection(title:'Твой аккаунт',subtitle:'Управляй доступом без выхода из приложения'),const SizedBox(height:14),
          Text('${account['username'] ?? ''} · ${account['email'] ?? ''}'),const SizedBox(height:6),
          Text(account['totp_enabled']==1||account['totp_enabled']==true?'Двухфакторная защита включена':'Двухфакторная защита пока выключена',style:const TextStyle(color:circleMuted)),
          const SizedBox(height:15),Wrap(spacing:8,runSpacing:8,children:[
            if(account['totp_enabled']==1||account['totp_enabled']==true)
              OutlinedButton.icon(onPressed:disableTotp,icon:const Icon(Icons.shield_outlined),label:const Text('Отключить 2FA'))
            else FilledButton.tonalIcon(onPressed:enableTotp,icon:const Icon(Icons.verified_user_outlined),label:const Text('Включить 2FA')),
          ]),const SizedBox(height:12),Wrap(spacing:10,runSpacing:10,children:[
            OutlinedButton.icon(onPressed:changeUsername,icon:const Icon(Icons.person_outline),label:const Text('Сменить логин')),
            FilledButton.icon(onPressed:changePassword,icon:const Icon(Icons.key_outlined),label:const Text('Сменить пароль')),
          ])])),const SizedBox(height:22),
        CircleSection(title:'Приложения и устройства',subtitle:'Токены, которые можно отозвать независимо'),const SizedBox(height:10),
        for(final d in devices) Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,spacing:10,runSpacing:8,children:[
          SizedBox(width:320,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${d['device_label'] ?? 'Circle'}',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:4),Text('Использовалось: ${d['last_used_at'] ?? '—'}',style:Theme.of(context).textTheme.bodySmall)])),
          if(d['current']==true)const Chip(label:Text('Это устройство')) else OutlinedButton(onPressed:()=>revoke(fxId(d['id']),'mobile'),child:const Text('Отозвать')),
        ]))),const SizedBox(height:14),const CircleSection(title:'Веб-сеансы'),const SizedBox(height:10),
        for(final d in sessions) Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,spacing:10,runSpacing:8,children:[
          SizedBox(width:320,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${d['device_label'] ?? 'Браузер'}',style:Theme.of(context).textTheme.titleMedium),Text('Последний вход: ${d['last_seen_at'] ?? '—'}',style:Theme.of(context).textTheme.bodySmall)])),
          OutlinedButton(onPressed:()=>revoke(fxId(d['id']),'web'),child:const Text('Завершить')),
        ]))),
      ]);
    }));
}

class DesktopCreateCommunity extends StatefulWidget {
  const DesktopCreateCommunity(this.api,{super.key});final CircleApi api;
  @override State<DesktopCreateCommunity> createState()=>_DesktopCreateCommunityState();
}
class _DesktopCreateCommunityState extends State<DesktopCreateCommunity>{
  final name=TextEditingController(),description=TextEditingController();bool busy=false;
  @override void dispose(){name.dispose();description.dispose();super.dispose();}
  Future<void> submit() async{
    if(busy)return;setState(()=>busy=true);
    try{final r=await widget.api.call('desktop-community-create',body:{'name':name.text.trim(),'description':description.text.trim()});
      if(mounted){fxNotice(context,'Сообщество создано · #${r['id']}');Navigator.pop(context,true);}}
    catch(e){if(mounted)fxNotice(context,e);}finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Новое сообщество',subtitle:'Вступление только по ссылке-приглашению',child:ListView(padding:const EdgeInsets.all(20),children:[
    CircleSurface(accent:true,child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const CircleSection(title:'Создай свой круг',subtitle:'Имя, описание и первый текстовый канал'),const SizedBox(height:18),
      TextField(controller:name,maxLength:80,decoration:const InputDecoration(labelText:'Название сообщества')),
      const SizedBox(height:12),TextField(controller:description,maxLength:500,maxLines:4,decoration:const InputDecoration(labelText:'Описание')),
      const SizedBox(height:16),Align(alignment:Alignment.centerRight,child:FilledButton.icon(onPressed:busy?null:submit,icon:const Icon(Icons.add_rounded),label:Text(busy?'Создаём...':'Создать сообщество')))
    ]))]));
}

class DesktopCommunityTools extends StatefulWidget {
  const DesktopCommunityTools(this.api,this.communityId,{super.key});
  final CircleApi api;final int communityId;
  @override State<DesktopCommunityTools> createState()=>_DesktopCommunityToolsState();
}
class _DesktopCommunityToolsState extends State<DesktopCommunityTools>{
  late Future<Map<String,dynamic>> panel;int tab=0;
  @override void initState(){super.initState();reload();}
  void reload(){panel=widget.api.call('desktop-community-panel',query:{'community_id':'${widget.communityId}'});}
  Future<void> perform(String route,Map<String,dynamic> body,{bool refresh=true}) async{
    try{await widget.api.call(route,body:{'community_id':widget.communityId,...body});if(mounted){fxNotice(context,'Сохранено');if(refresh)setState(reload);}}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> makeChannel() async{
    final name=await fxPrompt(context,'Название нового текстового канала');if(!mounted||name==null||name.isEmpty)return;
    await perform('desktop-channel-create',{'name':name});
  }
  Future<void> makeVoiceChannel() async {
    final name = await fxPrompt(context, 'Название голосового канала');
    if (!mounted || name == null || name.isEmpty) return;
    final permanent = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
      title: const Text('Тип голосового канала'),
      content: const Text('Временный канал доступен ограниченное время. Постоянный создаётся администратором сообщества.'),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Отмена')),
        OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Временный')),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Постоянный'))]));
    if (!mounted || permanent == null) return;
    await perform('desktop-voice-channel-create', {'name': name, 'channel_type': permanent ? 'PERMANENT' : 'TEMPORARY'});
  }
  Future<void> uploadCommunityImage(String kind) async {
    final file = await FilePicker.platform.pickFiles(type: FileType.image);
    if (!mounted || file == null || file.files.isEmpty || file.files.single.path == null) return;
    try {
      await widget.api.upload('desktop-community-image-upload', File(file.files.single.path!),
        field: 'attachment', fields: {'community_id': '${widget.communityId}', 'kind': kind});
      if (mounted) { setState(reload); fxNotice(context, 'Изображение обновлено'); }
    } catch (e) { if (mounted) fxNotice(context, e); }
  }
  Future<void> editRole(Map<String,dynamic> role) async {
    const all = ['SEND_MESSAGES','CONNECT_VOICE','MANAGE_MESSAGES','MANAGE_CHANNELS',
      'MANAGE_MEMBERS','MANAGE_ROLES','CREATE_TEMP_VOICE','MENTION_EVERYONE','MANAGE_COMMUNITY'];
    final chosen = <String>{...((role['permissions'] as List? ?? []).map((e) => '$e'))};
    final permissions = await showDialog<List<String>>(context: context, builder: (dialog) => StatefulBuilder(
      builder: (dialog, refreshDialog) => AlertDialog(
        title: Text('Права роли: ${role['name']}'),
        content: SizedBox(width: 440, height: 380, child: ListView(children: [
          for (final permission in all) CheckboxListTile(
            dense: true, title: Text(permission), value: chosen.contains(permission),
            onChanged: (value) => refreshDialog(() => value == true ? chosen.add(permission) : chosen.remove(permission)))
        ])), actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(dialog, chosen.toList()), child: const Text('Сохранить права'))])));
    if (!mounted || permissions == null) return;
    await perform('desktop-role-permissions', {'role_id': fxId(role['id']), 'permissions': permissions});
  }
  Future<void> makeInvite() async{
    try{final r=await widget.api.call('desktop-invite-create',body:{'community_id':widget.communityId,'expires_days':7,'max_uses':50});
      if(!mounted)return;final uri=widget.api.base.resolve('${r['path'] ?? ''}').toString();
      await showDialog<void>(context:context,builder:(dialog)=>AlertDialog(title:const Text('Ссылка-приглашение'),content:SizedBox(width:470,child:SelectableText(uri)),actions:[TextButton(onPressed:(){Clipboard.setData(ClipboardData(text:uri));Navigator.pop(dialog);},child:const Text('Скопировать и закрыть'))]));
      if(mounted)setState(reload);
    }catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> editAppearance(Map<String,dynamic> current) async {
    final name = TextEditingController(text: '${current['name'] ?? ''}');
    final description = TextEditingController(text: '${current['description'] ?? ''}');
    var news = current['news_enabled']==true || '${current['news_enabled']}'=='1';
    var chat = current['chat_enabled']==true || '${current['chat_enabled']}'=='1';
    var voice = current['voice_enabled']==true || '${current['voice_enabled']}'=='1';
    final settings = await showDialog<Map<String,dynamic>>(context: context,
      builder: (dialog) => StatefulBuilder(builder: (dialog, updateDialog) => AlertDialog(
        title: const Text('Оформление и возможности'),
        content: SizedBox(width: 490,child: SingleChildScrollView(child: Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:name,maxLength:80,decoration:const InputDecoration(labelText:'Название сообщества')),
          const SizedBox(height:10),TextField(controller:description,maxLines:3,maxLength:500,decoration:const InputDecoration(labelText:'Описание')),
          SwitchListTile(title:const Text('Новости сообщества'),value:news,onChanged:(v)=>updateDialog(()=>news=v)),
          SwitchListTile(title:const Text('Текстовые каналы'),value:chat,onChanged:(v)=>updateDialog(()=>chat=v)),
          SwitchListTile(title:const Text('Голосовые комнаты'),value:voice,onChanged:(v)=>updateDialog(()=>voice=v)),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialog),child:const Text('Отмена')),
          FilledButton(onPressed:()=>Navigator.pop(dialog,{
            'name':name.text.trim(),'description':description.text.trim(),
            'news_enabled':news,'chat_enabled':chat,'voice_enabled':voice,
            'banner_zoom':fxId(current['banner_zoom']??100),
            'banner_pos_x':fxId(current['banner_pos_x']??50),
            'banner_pos_y':fxId(current['banner_pos_y']??50),
          }),child:const Text('Сохранить'))])));
    if (!mounted || settings==null) return;
    await perform('desktop-community-appearance',settings);
  }
  Future<void> createRole()async{
    final name=await fxPrompt(context,'Название новой роли');if(!mounted||name==null||name.isEmpty)return;
    await perform('desktop-role-create',{'name':name,'color':'#C6A15B','badge_icon':'✦','permissions':['SEND_MESSAGES','CONNECT_VOICE']});
  }
  Future<void> setAutomod(Map<String,dynamic> d) async{
    final secs=await fxPrompt(context,'Задержка между сообщениями (секунды)',initial:'${d['slowmode_seconds'] ?? 0}');if(!mounted||secs==null)return;
    await perform('desktop-automod',{'enabled':d['enabled']==true||d['enabled']==1||d['enabled']=='1',
      'block_invites':d['block_invites']==true||d['block_invites']==1||d['block_invites']=='1',
      'block_external_links':d['block_external_links']==true||d['block_external_links']==1||d['block_external_links']=='1','slowmode_seconds':fxId(secs)});
  }
  Future<void> ban(Map<String,dynamic> member) async{
    final reason=await fxPrompt(context,'Причина блокировки участника');if(!mounted||reason==null||reason.length<3)return;
    if(!await fxConfirm(context,'Заблокировать участника?','${member['username'] ?? ''} потеряет доступ к сообществу.'))return;
    await perform('desktop-member-ban',{'user_id':fxId(member['id']),'reason':reason});
  }
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Управление сообществом',subtitle:'Роли, каналы, приглашения и модерация',child:FutureBuilder<Map<String,dynamic>>(future:panel,builder:(context,s){
    if(s.hasError)return CircleEmpty(title:'Не удалось загрузить настройки',description:'${s.error}',action:OutlinedButton(onPressed:()=>setState(reload),child:const Text('Повторить')));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final data=s.data!,appearance=fxMap(data['appearance']),channels=fxRows(data['channels']),voiceChannels=fxRows(data['voice_channels']),members=fxRows(data['members']),roles=fxRows(data['roles']),invites=fxRows(data['invites']),automod=fxMap(data['automod']);
    final tabs=['Каналы','Голосовые','Участники','Роли','Приглашения','Автомодерация'];
    return ListView(padding:const EdgeInsets.all(20),children:[
      if(data['can_manage']==true) Padding(padding:const EdgeInsets.only(bottom:16),child:Wrap(spacing:8,runSpacing:8,children:[
        FilledButton.tonalIcon(onPressed:()=>editAppearance(appearance),icon:const Icon(Icons.tune),label:const Text('Настройки сообщества')),
        OutlinedButton.icon(onPressed:()=>uploadCommunityImage('icon'),icon:const Icon(Icons.account_circle_outlined),label:const Text('Аватар сообщества')),
        OutlinedButton.icon(onPressed:()=>uploadCommunityImage('banner'),icon:const Icon(Icons.image_outlined),label:const Text('Обложка сообщества'))])),
      Wrap(spacing:8,runSpacing:8,children:[for(var i=0;i<tabs.length;i++)ChoiceChip(label:Text(tabs[i]),selected:tab==i,onSelected:(_)=>setState(()=>tab=i))]),
      const SizedBox(height:18),
      if(tab==0)...[
        CircleSection(title:'Текстовые каналы',subtitle:'Настройки и структура',trailing:data['can_manage_channels']==true?OutlinedButton.icon(onPressed:makeChannel,icon:const Icon(Icons.add),label:const Text('Добавить')):null),
        const SizedBox(height:13),for(final c in channels) Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,spacing:10,runSpacing:8,children:[
          Text('# ${c['name'] ?? ''}',style:Theme.of(context).textTheme.titleMedium),
          if(data['can_manage_channels']==true)Wrap(spacing:4,children:[IconButton(tooltip:'Переименовать',onPressed:() async{final name=await fxPrompt(context,'Название канала',initial:'${c['name']}');if(mounted&&name!=null)await perform('desktop-channel-rename',{'channel_id':fxId(c['id']),'name':name});},icon:const Icon(Icons.edit_outlined)),
          IconButton(tooltip:'Удалить канал',onPressed:()async{if(await fxConfirm(context,'Удалить канал?','Сообщения и вложения в нём будут удалены безвозвратно.'))await perform('desktop-channel-delete',{'channel_id':fxId(c['id']),'confirm_name':'${c['name']}'});},icon:const Icon(Icons.delete_outline,color:circleRed))])
        ])))],
      if(tab==1)...[
        CircleSection(title:'Голосовые комнаты', subtitle:'Временные и постоянные каналы',
          trailing:OutlinedButton.icon(onPressed:makeVoiceChannel,icon:const Icon(Icons.add),label:const Text('Создать'))),
        const SizedBox(height:13),
        for(final vc in voiceChannels) Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(
          spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[
            Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.graphic_eq,color:circleGold),const SizedBox(width:9),
              Text('${vc['name']} · ${vc['channel_type']}',style:Theme.of(context).textTheme.titleMedium)]),
            if(data['can_manage_channels']==true) OutlinedButton.icon(
              onPressed:()=>perform('desktop-voice-channel-lock',{
                'channel_id':fxId(vc['id']),'locked':!('${vc['is_locked']}'=='1'||vc['is_locked']==true)}),
              icon:Icon('${vc['is_locked']}'=='1'?Icons.lock_open_outlined:Icons.lock_outline),
              label:Text('${vc['is_locked']}'=='1'?'Открыть':'Закрыть'))
          ])))],
      if(tab==2)...[CircleSection(title:'Участники',subtitle:'Показаны первые 150 участников'),const SizedBox(height:13),
        for(final m in members)Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[
          Text('${m['display_name'] ?? m['username']}  ·  ${m['member_role'] ?? ''}',style:Theme.of(context).textTheme.titleMedium),
          if(data['can_manage']==true&&'${m['member_role']}'!='OWNER')Wrap(spacing:6,children:[
            if(roles.isNotEmpty)PopupMenuButton<int>(tooltip:'Назначить роль',onSelected:(role)=>perform('desktop-role-assign',{'user_id':fxId(m['id']),'role_id':role}),itemBuilder:(_)=>[for(final r in roles)PopupMenuItem(value:fxId(r['id']),child:Text('${r['name']}'))],child:const Chip(label:Text('Назначить роль'))),
            IconButton(tooltip:'Заблокировать',onPressed:()=>ban(m),icon:const Icon(Icons.person_off_outlined,color:circleRed))])
        ])))],
      if(tab==3)...[CircleSection(title:'Роли и права',subtitle:'Разрешения проверяются на сервере',trailing:data['can_manage']==true?OutlinedButton(onPressed:createRole,child:const Text('Создать роль')):null),const SizedBox(height:13),
        for(final r in roles)Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('${r['badge_icon'] ?? ''} ${r['name'] ?? ''}',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:8),Wrap(spacing:5,runSpacing:5,children:[for(final p in (r['permissions'] as List? ?? []))Chip(label:Text('$p'))]),
          if(data['can_manage']==true) Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>editRole(r),icon:const Icon(Icons.manage_accounts_outlined),label:const Text('Изменить разрешения')))
        ])))],
      if(tab==4)...[CircleSection(title:'Приглашения',subtitle:'Вступление исключительно по ссылке',trailing:data['can_manage']==true?OutlinedButton(onPressed:makeInvite,child:const Text('Создать ссылку')):null),const SizedBox(height:13),
        const Text('Существующие токены не отображаются повторно: ссылки можно скопировать только в момент создания.',style:TextStyle(color:circleMuted)),const SizedBox(height:12),
        for(final i in invites)Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,spacing:8,runSpacing:8,children:[
          Text('Приглашение #${i['id']} · использовано ${i['uses']}/${i['max_uses'] ?? '∞'}'),
          if(i['revoked_at']==null)TextButton(onPressed:()=>perform('desktop-invite-revoke',{'invite_id':fxId(i['id'])}),child:const Text('Отозвать')) else const Text('Отозвано',style:TextStyle(color:circleMuted))
        ])))],
      if(tab==5)...[const CircleSection(title:'Автомодерация',subtitle:'Фильтры ссылок, приглашений и антиспам'),const SizedBox(height:14),
        CircleSurface(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('Замедление сообщений: ${automod['slowmode_seconds'] ?? 0} сек.'),const SizedBox(height:8),
          Text('Блокировать приглашения: ${automod['block_invites'] ?? '—'}'),Text('Блокировать ссылки: ${automod['block_external_links'] ?? '—'}'),const SizedBox(height:12),
          if(data['can_manage_messages']==true)FilledButton(onPressed:()=>setAutomod(automod),child:const Text('Изменить интервал')),
        ]))],
    ]);
  }));
}

class DesktopArchiveScreen extends StatefulWidget{
  const DesktopArchiveScreen(this.api,{super.key});final CircleApi api;
  @override State<DesktopArchiveScreen> createState()=>_DesktopArchiveScreenState();
}
class _DesktopArchiveScreenState extends State<DesktopArchiveScreen>{
  late Future<Map<String,dynamic>> future;@override void initState(){super.initState();reload();}
  void reload(){future=widget.api.call('desktop-dm-archives');}
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Архив переписок',child:FutureBuilder<Map<String,dynamic>>(future:future,builder:(context,s){
    if(s.hasError)return CircleEmpty(title:'Архив не загрузился',description:'${s.error}');
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final rows=fxRows(s.data!['items']);if(rows.isEmpty)return const CircleEmpty(title:'Архив пуст',icon:Icons.archive_outlined);
    return ListView.builder(padding:const EdgeInsets.all(20),itemCount:rows.length,itemBuilder:(context,i){final r=rows[i];return Padding(padding:const EdgeInsets.only(bottom:8),child:CircleSurface(child:Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[
      Text('${fxMap(r['peer'])['display_name'] ?? fxMap(r['peer'])['username'] ?? 'Диалог'}'),OutlinedButton(onPressed:()async{try{await widget.api.call('desktop-dm-archive',body:{'conversation_id':fxId(r['id']),'archived':false});if(mounted)setState(reload);}catch(e){if(mounted)fxNotice(context,e);}},child:const Text('Вернуть из архива'))
    ])));});
  }));
}

class DesktopMeetingsScreen extends StatefulWidget{
  const DesktopMeetingsScreen(this.api,{super.key});final CircleApi api;
  @override State<DesktopMeetingsScreen> createState()=>_DesktopMeetingsScreenState();
}
class _DesktopMeetingsScreenState extends State<DesktopMeetingsScreen>{
  late Future<Map<String,dynamic>> meetings;late Future<Map<String,dynamic>> friends;final Set<int> selected={};
  @override void initState(){super.initState();refresh();friends=widget.api.call('friends');}
  void refresh(){meetings=widget.api.call('desktop-meetings');}
  Future<void> enter(int id,String title) async{
    try{await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>CircleLiveRoom(title:title,credentials:()=>widget.api.call('desktop-meeting-token',body:{'meeting_id':id}))));}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> create() async{
    if(selected.length<2){fxNotice(context,'Выбери минимум двух друзей');return;}
    final title=await fxPrompt(context,'Название групповой встречи',initial:'Встреча Circle');if(!mounted||title==null)return;
    try{final r=await widget.api.call('desktop-meeting-create',body:{'title':title,'user_ids':selected.toList()});if(!mounted)return;
      setState(refresh);await enter(fxId(r['id']),title);
    }catch(e){if(mounted)fxNotice(context,e);}
  }
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Групповые встречи',subtitle:'Голосовые и видеозвонки с друзьями через LiveKit',child:ListView(padding:const EdgeInsets.all(20),children:[
    const CircleSection(title:'Собери свой круг',subtitle:'Выбери от 2 до 19 друзей'),const SizedBox(height:12),
    FutureBuilder<Map<String,dynamic>>(future:friends,builder:(context,s){
      if(!s.hasData)return const SizedBox(height:48,child:Center(child:CircularProgressIndicator()));
      final items=fxRows(s.data!['items']);return CircleSurface(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Wrap(spacing:6,runSpacing:6,children:[for(final item in items)FilterChip(label:Text('${item['display_name'] ?? item['username'] ?? fxMap(item['user'])['display_name'] ?? 'Друг'}'),
          selected:selected.contains(fxId(item['id']??fxMap(item['user'])['id'])),onSelected:(v){final id=fxId(item['id']??fxMap(item['user'])['id']);if(id>0)setState((){if(v){selected.add(id);}else{selected.remove(id);}});})]),
        const SizedBox(height:14),FilledButton.icon(onPressed:selected.length>=2?create:null,icon:const Icon(Icons.groups),label:Text('Начать встречу (${selected.length})'))
      ]));}),const SizedBox(height:24),const CircleSection(title:'Активные встречи'),const SizedBox(height:12),
    FutureBuilder<Map<String,dynamic>>(future:meetings,builder:(context,s){if(!s.hasData)return const SizedBox(height:48,child:Center(child:CircularProgressIndicator()));
      final rooms=fxRows(s.data!['items']);return Column(children:[for(final r in rooms)Padding(padding:const EdgeInsets.only(bottom:8),child:CircleSurface(child:ListTile(leading:const Icon(Icons.call,color:circleGold),title:Text('${r['title']}'),subtitle:Text('Встреча #${r['id']}'),trailing:const Icon(Icons.arrow_forward_ios_rounded,size:15),onTap:()=>enter(fxId(r['id']),'${r['title']}'))))]);})
  ]));
}

class DesktopTrustScreen extends StatefulWidget{
  const DesktopTrustScreen(this.api,{super.key});final CircleApi api;
  @override State<DesktopTrustScreen> createState()=>_DesktopTrustScreenState();
}
class _DesktopTrustScreenState extends State<DesktopTrustScreen>{
  String category='LOCAL_POLICY', severity='MEDIUM';
  late Future<Map<String,dynamic>> panel;@override void initState(){super.initState();refresh();}
  void refresh(){panel=widget.api.call('desktop-trust-panel');}
  Future<void> addRule()async{
    final phrase=await fxPrompt(context,'Запрещённое выражение');if(!mounted||phrase==null)return;
    try{await widget.api.call('desktop-trust-rule-add',body:{'phrase':phrase,'category':category,'severity':severity});if(mounted)setState(refresh);}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> importRules() async {
    final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['txt','docx']);
    if(!mounted||picked==null||picked.files.isEmpty)return;
    final path=picked.files.single.path;if(path==null)return;
    try{
      final response=await widget.api.upload('desktop-trust-import',File(path),field:'rules_document',fields:{'category':category,'severity':severity});
      if(mounted){fxNotice(context,'Импортировано правил: ${response['count'] ?? 0}');setState(refresh);}
    }catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> toggleRule(int id) async {
    try{await widget.api.call('desktop-trust-rule-toggle',body:{'rule_id':id});if(mounted)setState(refresh);}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  Future<void> resolve(int id,String status)async{
    final note=await fxPrompt(context,'Основание решения ($status)',lines:3);if(!mounted||note==null)return;
    try{await widget.api.call('desktop-trust-review',body:{'case_id':id,'status':status,'note':note});if(mounted)setState(refresh);}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  @override Widget build(BuildContext context)=>DesktopFrame(title:'Trust & Safety',subtitle:'Журнал модерации Circle · только для администраторов',child:FutureBuilder<Map<String,dynamic>>(future:panel,builder:(context,s){
    if(s.hasError)return CircleEmpty(title:'Панель модерации недоступна',description:'${s.error}');
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final cases=fxRows(s.data!['cases']),rules=fxRows(s.data!['rules']);return ListView(padding:const EdgeInsets.all(20),children:[
      CircleSection(title:'Проверка материалов',subtitle:'Сначала проверка человеком, затем решение',trailing:Wrap(spacing:8,runSpacing:8,children:[OutlinedButton.icon(onPressed:importRules,icon:const Icon(Icons.upload_file),label:const Text('Импорт TXT/DOCX')),OutlinedButton.icon(onPressed:addRule,icon:const Icon(Icons.add),label:const Text('Добавить правило'))])),const SizedBox(height:14),
      CircleSurface(child:Wrap(spacing:18,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[
        const Text('Новые правила:'),DropdownButton<String>(value:category,items:const [
          DropdownMenuItem(value:'LOCAL_POLICY',child:Text('Локальные запреты')),
          DropdownMenuItem(value:'PROHIBITED_MATERIAL',child:Text('Запрещённые материалы')),
          DropdownMenuItem(value:'THREAT',child:Text('Угрозы')),
          DropdownMenuItem(value:'SPAM',child:Text('Спам')),
          DropdownMenuItem(value:'HARASSMENT',child:Text('Травля'))],
          onChanged:(v){if(v!=null)setState((){category=v;if(severity=='HIGH'&&v!='PROHIBITED_MATERIAL'&&v!='THREAT')severity='MEDIUM';});}),
        DropdownButton<String>(value:severity,items:[const DropdownMenuItem(value:'LOW',child:Text('Низкий')),
          const DropdownMenuItem(value:'MEDIUM',child:Text('Средний')),
          if(category=='PROHIBITED_MATERIAL'||category=='THREAT')const DropdownMenuItem(value:'HIGH',child:Text('Высокий'))],
          onChanged:(v){if(v!=null)setState(()=>severity=v);})])),
      const SizedBox(height:14),
      for(final c in cases)Padding(padding:const EdgeInsets.only(bottom:9),child:CircleSurface(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Случай #${c['id']} · ${c['source_type']} · ${c['username']}',style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:7),Text('${c['excerpt'] ?? ''}'),const SizedBox(height:12),
        Wrap(spacing:7,runSpacing:7,children:[OutlinedButton(onPressed:()=>resolve(fxId(c['id']),'REVIEWING'),child:const Text('На проверку')),
          FilledButton(onPressed:()=>resolve(fxId(c['id']),'CONFIRMED'),child:const Text('Подтвердить')),
          OutlinedButton(onPressed:()=>resolve(fxId(c['id']),'DISMISSED'),child:const Text('Отклонить'))])]))),
      const SizedBox(height:22),CircleSection(title:'Правила (${rules.length})'),const SizedBox(height:12),
      for(final r in rules)Padding(padding:const EdgeInsets.only(bottom:6),child:CircleSurface(padding:const EdgeInsets.all(12),child:Wrap(spacing:12,runSpacing:8,alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,children:[Text('${r['phrase']} · ${r['category']} · ${r['severity']}'),OutlinedButton(onPressed:()=>toggleRule(fxId(r['id'])),child:Text(r['enabled']==true||'${r['enabled']}'=='1'?'Выключить':'Включить'))])))
    ]);
  }));
}
