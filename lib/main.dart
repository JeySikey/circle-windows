import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'api.dart';
import 'updater.dart';

const gold = Color(0xffc6a15b), back = Color(0xff101114), panel = Color(0xff1d1e22);
const secure = FlutterSecureStorage();
const updateManifest = String.fromEnvironment('CIRCLE_UPDATE_URL');
const updatePublicKey = String.fromEnvironment('CIRCLE_UPDATE_PUBLIC_KEY');
const appVersion = '0.3.2';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(const WindowOptions(size: Size(1250, 800), minimumSize: Size(780, 540), title: 'Circle — Твой круг. Твои люди.'), () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const CircleApp());
}

class CircleApp extends StatelessWidget {
  const CircleApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Circle', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, scaffoldBackgroundColor: back,
      colorScheme: ColorScheme.fromSeed(seedColor: gold, brightness: Brightness.dark),
      cardTheme: const CardThemeData(color: panel), inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      appBarTheme: const AppBarTheme(backgroundColor: back)),
    home: const CircleRoot(),
  );
}

class CircleRoot extends StatefulWidget {const CircleRoot({super.key}); @override State<CircleRoot> createState()=>_CircleRootState();}
class _CircleRootState extends State<CircleRoot> {
  CircleApi? api;
  Map<String, dynamic> me = {};
  bool loading = true;
  int page = 0;
  String error = '';
  @override void initState(){super.initState(); restore();}
  Future<void> restore() async {
    final server = await secure.read(key:'circle_server');
    final token = await secure.read(key:'circle_token');
    if (server != null && token != null) {
      try { final client = CircleApi(server)..token = token; final data = await client.call('me');
        if (mounted) setState(() {api=client;me=obj(data['user']);});
      } catch (_) {await secure.delete(key:'circle_token');}
    }
    if (mounted) setState(()=>loading=false);
  }
  Future<void> login(String server,String user,String password,String totp) async {
    setState(()=>loading=true);
    try {
      final client = CircleApi(server);
      final data = await client.call('login', auth:false, body:{'login':user,'password':password,'totp_code':totp,'device':'Circle Windows Native'});
      client.token='${data['token']}';
      await secure.write(key:'circle_server',value:server);
      await secure.write(key:'circle_token',value:client.token);
      if(mounted)setState(() {api?.dispose();api=client;me=obj(data['user']);error='';});
    } catch(e) {if(mounted)setState(()=>error='$e');}
    if(mounted)setState(()=>loading=false);
  }
  Future<void> logout() async {
    try{await api?.call('logout',body:{});}catch(_){/* local logout still applies */}
    await secure.delete(key:'circle_token');
    api?.dispose(); if(mounted)setState(() {api=null; me={}; page=0;});
  }
  @override Widget build(BuildContext context) {
    if(loading) return const Scaffold(body:Center(child:CircularProgressIndicator()));
    if(api==null)return LoginScreen(onLogin:login,error:error);
    final a = api!;
    final screens = [FeedScreen(a),ProfileScreen(a),MessengerScreen(a),FriendsScreen(a),CommunitiesScreen(a),NotificationsScreen(a), CallsScreen(a), const UpdatesScreen()];
    final titles=['Главная','Профиль','Мессенджер','Друзья','Сообщества','Уведомления','Звонки','Обновления'];
    final icons=[Icons.home_outlined,Icons.person_outline,Icons.forum_outlined,Icons.people_outline,Icons.groups_outlined,Icons.notifications_outlined,Icons.call_outlined,Icons.system_update_outlined];
    return Scaffold(body:Row(children:[
      NavigationRail(backgroundColor:panel, selectedIndex:page, extended:MediaQuery.sizeOf(context).width>1100,
        minExtendedWidth:185, onDestinationSelected:(i)=>setState(()=>page=i),
        leading:const Padding(padding:EdgeInsets.symmetric(vertical:20),child:Text('◉ CIRCLE',style:TextStyle(color:gold,fontSize:21,fontWeight:FontWeight.w800))),
        trailing:Expanded(child:Align(alignment:Alignment.bottomCenter,child:IconButton(tooltip:'Выйти',onPressed:logout,icon:const Icon(Icons.logout)))),
        destinations:[for(int i=0;i<titles.length;i++)NavigationRailDestination(icon:Icon(icons[i]),label:Text(titles[i]))]),
      const VerticalDivider(width:1),Expanded(child:Column(children:[
        AppBar(title:Text(titles[page]),actions:[Text(label(me)),const SizedBox(width:20)]),
        Expanded(child:IndexedStack(index:page,children:screens))]))]));
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key,required this.onLogin,required this.error});
  final Future<void> Function(String,String,String,String) onLogin;
  final String error;
  @override State<LoginScreen> createState()=>_LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final host=TextEditingController(text:'https://acircle.ru'),user=TextEditingController(),pass=TextEditingController(),totp=TextEditingController();
  @override void dispose(){
    for(final c in [host,user,pass,totp]) {
      c.dispose();
    }
    super.dispose();
  }
  @override Widget build(BuildContext context)=> Scaffold(body:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Card(child:Padding(padding:const EdgeInsets.all(26),child:Column(mainAxisSize:MainAxisSize.min,children:[
    const Text('◉ CIRCLE',style:TextStyle(color:gold,fontSize:30,fontWeight:FontWeight.bold)),
    const SizedBox(height:6),const Text('Твой круг. Твои люди.'),const SizedBox(height:26),
    TextField(controller:host,decoration:const InputDecoration(labelText:'Сервер HTTPS')),
    const SizedBox(height:10),TextField(controller:user,decoration:const InputDecoration(labelText:'Логин или email')),
    const SizedBox(height:10),TextField(controller:pass,obscureText:true,decoration:const InputDecoration(labelText:'Пароль')),
    const SizedBox(height:10),TextField(controller:totp,decoration:const InputDecoration(labelText:'Код 2FA (если включён)')),
    if(widget.error.isNotEmpty) Padding(padding:const EdgeInsets.all(10),child:Text(widget.error,style:const TextStyle(color:Colors.redAccent))),
    const SizedBox(height:16),FilledButton(onPressed:()=>widget.onLogin(host.text.trim(),user.text.trim(),pass.text,totp.text.trim()),child:const Text('Войти'))]))))));
}

class ApiList extends StatefulWidget {
  const ApiList({super.key,required this.api,required this.route,required this.itemBuilder,this.query=const {}});
  final CircleApi api;final String route;final Map<String,String> query;
  final Widget Function(BuildContext,Map<String,dynamic>,VoidCallback) itemBuilder;
  @override State<ApiList> createState()=>_ApiListState();
}
class _ApiListState extends State<ApiList> {
  late Future<List<Map<String,dynamic>>> future;
  @override void initState(){super.initState();load();}
  @override void didUpdateWidget(covariant ApiList old){super.didUpdateWidget(old);if(old.route!=widget.route||old.query.toString()!=widget.query.toString()||old.api!=widget.api)load();}
  void load(){future=widget.api.call(widget.route,query:widget.query).then(items);}
  void refresh(){setState(load);}
  @override Widget build(BuildContext context)=>FutureBuilder<List<Map<String,dynamic>>>(future:future,builder:(context,s){
    if(s.hasError)return Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Text('${s.error}'),TextButton(onPressed:refresh,child:const Text('Повторить'))]));
    if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final values=s.data!;return RefreshIndicator(onRefresh:()async {refresh();await future;},child:ListView(padding:const EdgeInsets.all(16),children:[
      if(values.isEmpty) const Padding(padding:EdgeInsets.all(30),child:Center(child:Text('Пока ничего нет'))),
      for(final item in values)widget.itemBuilder(context,item,refresh)]));
  });
}
void notify(BuildContext context,String msg){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(msg)));}
Future<String?> compose(BuildContext context,String title,{String initial=''}) async {
  final controller=TextEditingController(text:initial);
  final result=await showDialog<String>(context:context,builder:(c)=>AlertDialog(title:Text(title),content:SizedBox(width:470,child:TextField(controller:controller,maxLines:5,maxLength:10000,autofocus:true)),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Отмена')),FilledButton(onPressed:()=>Navigator.pop(c,controller.text.trim()),child:const Text('Отправить'))]));controller.dispose();return result;
}
class FeedScreen extends StatelessWidget {
  const FeedScreen(this.api,{super.key,this.route='feed',this.query=const {}}); final CircleApi api;
  final String route;final Map<String,String> query;
  @override Widget build(BuildContext context)=>Column(children:[
    if(route=='feed') SizedBox(height:132,child:StoriesStrip(api)),
    if(route=='feed')Padding(padding:const EdgeInsets.all(12),child:Row(children:[FilledButton.icon(icon:const Icon(Icons.edit),label:const Text('Новая публикация'),onPressed:()async {
      final title=await compose(context,'Заголовок публикации');if(!context.mounted||title==null||title.isEmpty)return;
      final content=await compose(context,'Текст публикации');if(!context.mounted||content==null)return;
      try{await api.call('post-create',body:{'title':title,'body':content});if(context.mounted)notify(context,'Опубликовано');}catch(e){if(context.mounted)notify(context,'$e');}
    }),const SizedBox(width:12),OutlinedButton.icon(icon:const Icon(Icons.photo_library_outlined),label:const Text('С медиа'),onPressed:()async {
      final title=await compose(context,'Заголовок публикации');if(!context.mounted||title==null||title.isEmpty)return;
      final body=await compose(context,'Текст публикации');if(!context.mounted||body==null)return;
      final file=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['png','jpg','jpeg','webp','gif','mp4','webm']);if(file==null||file.files.single.path==null)return;
      try{await api.upload('post-upload',File(file.files.single.path!),field:'media',fields:{'title':title,'body':body});if(context.mounted)notify(context,'Медиа опубликовано');}catch(e){if(context.mounted)notify(context,'$e');}
    }),const SizedBox(width:12),const Text('Лента друзей и сообществ')])),
    Expanded(child:ApiList(api:api,route:route,query:query,itemBuilder:(c,item,refresh)=>PostCard(api,item,refresh))) ]);
}
class PostCard extends StatelessWidget {
  const PostCard(this.api,this.post,this.refresh,{super.key});final CircleApi api; final Map<String,dynamic> post;final VoidCallback refresh;
  @override Widget build(BuildContext context){final p=obj(post['author']),st=obj(post['stats']);final id=identifier(post['id']);
    return Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label(p),style:const TextStyle(color:gold,fontWeight:FontWeight.w700)),const SizedBox(height:6),
      if('${post['title']??''}'.isNotEmpty)Text('${post['title']}',style:Theme.of(context).textTheme.titleLarge),
      SelectableText('${post['body']??''}'),
      if(post['has_media']==true) Padding(padding:const EdgeInsets.only(top:12),child:FutureBuilder<List<int>>(future:api.media('post-media',id),builder:(context,s)=>s.hasData&&'${post['media_mime']}'.startsWith('image/')?Image.memory(Uint8List.fromList(s.data!),height:260,fit:BoxFit.contain):Text(s.hasError?'Медиа недоступно':'Медиа: ${post['media_mime']}'))),
      const SizedBox(height:8),Wrap(spacing:10,children:[
        TextButton.icon(onPressed:()async {try{await api.call('post-like',body:{'post_id':id});refresh();}catch(e){if(context.mounted)notify(context,'$e');}},icon:const Icon(Icons.favorite_border),label:Text('${st['likes']??''} Нравится')),
        TextButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CommentsScreen(api,id))),icon:const Icon(Icons.chat_bubble_outline),label:Text('${st['comments']??''} Комментарии')),
      ])])));
  }
}
class CommentsScreen extends StatefulWidget {const CommentsScreen(this.api,this.postId,{super.key});final CircleApi api;final int postId;@override State<CommentsScreen> createState()=>_CommentsScreenState();}
class _CommentsScreenState extends State<CommentsScreen>{int? parent;
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Комментарии')),body:Column(children:[Expanded(child:ApiList(key:ValueKey('${widget.postId}-$parent'),api:widget.api,route:'post-comments',query:{'post_id':'${widget.postId}'},itemBuilder:(c,item,refresh)=>ListTile(title:Text(label(obj(item['author']))),subtitle:Text('${item['body']}${item['parent_comment_id']!=null?' · ответ':''}'),trailing:TextButton(onPressed:()=>setState(()=>parent=identifier(item['id'])),child:const Text('Ответить'))))),
    if(parent!=null)ListTile(title:Text('Ответ на комментарий #$parent'),trailing:IconButton(onPressed:()=>setState(()=>parent=null),icon:const Icon(Icons.close))),
    Padding(padding:const EdgeInsets.all(12),child:FilledButton(onPressed:()async {final txt=await compose(context,'Комментарий');if(txt==null||txt.isEmpty)return;
      try{await widget.api.call('post-comment',body:{'post_id':widget.postId,'body':txt,'parent_comment_id':parent??0});if(mounted)setState(()=>parent=null);}
      catch(e){if(context.mounted)notify(context,'$e');}},child:const Text('Написать комментарий')))]));
}
class ProfileScreen extends StatefulWidget {const ProfileScreen(this.api,{super.key});final CircleApi api;@override State<ProfileScreen> createState()=>_ProfileScreenState();}
class _ProfileScreenState extends State<ProfileScreen>{late Future<Map<String,dynamic>> profile;
  @override void initState(){super.initState();profile=widget.api.call('profile');}
  void reload()=>setState(()=>profile=widget.api.call('profile'));
  @override Widget build(BuildContext context)=>FutureBuilder<Map<String,dynamic>>(future:profile,builder:(c,s){
    if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());
    final d=s.data!,u=obj(d['user']);return ListView(padding:const EdgeInsets.all(20),children:[
      Text(label(u),style:Theme.of(context).textTheme.headlineMedium),Text('@${u['username']??''}',style:const TextStyle(color:gold)),
      const SizedBox(height:8),Text('${d['status_text']??''}'),Text('${d['bio']??''}'),
      Align(alignment:Alignment.centerLeft,child:FilledButton.icon(onPressed:()async {final name=await compose(context,'Отображаемое имя',initial:label(u));if(!context.mounted||name==null||name.isEmpty)return;
        final bio=await compose(context,'О себе',initial:'${d['bio']??''}');if(!context.mounted||bio==null)return;
        try {await widget.api.call('profile-save',body:{'display_name':name,'bio':bio,'status_text':'${d['status_text']??''}','visibility':'${d['visibility']??'PUBLIC'}'});reload();}catch(e){if(context.mounted)notify(context,'$e');}
      },icon:const Icon(Icons.edit),label:const Text('Редактировать профиль'))),
      const Divider(),const Text('Мои публикации',style:TextStyle(fontSize:20,color:gold)),SizedBox(height:600,child:FeedScreen(widget.api,route:'profile-posts'))]);
  });
}
class FriendsScreen extends StatelessWidget {const FriendsScreen(this.api,{super.key});final CircleApi api;
  @override Widget build(BuildContext context)=>ApiList(api:api,route:'friends',itemBuilder:(c,i,r)=>Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.person)),title:Text(label(i)),subtitle:Text('@${i['username']}'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>PublicProfile(api,identifier(i['id'])))))));
}
class PublicProfile extends StatelessWidget {const PublicProfile(this.api,this.id,{super.key});final CircleApi api;final int id;
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Профиль')),body:FutureBuilder<Map<String,dynamic>>(future:api.call('user-profile',query:{'id':'$id'}),builder:(c,s){if(!s.hasData)return Center(child:Text('${s.error??'Загрузка...'}'));final u=obj(s.data!['user']);return ListView(children:[ListTile(title:Text(label(u)),subtitle:Text('${s.data!['bio']??''}')),SizedBox(height:650,child:FeedScreen(api,route:'profile-posts',query:{'user_id':'$id'}))]);}));
}
class MessengerScreen extends StatelessWidget {const MessengerScreen(this.api,{super.key});final CircleApi api;
  @override Widget build(BuildContext context)=>ApiList(api:api,route:'conversations',itemBuilder:(c,i,r)=>Card(child:ListTile(title:Text(label(obj(i['peer'])) == 'Пользователь'?'Диалог #${i['id']}':label(obj(i['peer']))),subtitle:Text('${i['last_message']??''}',maxLines:1),trailing:const Icon(Icons.chevron_right),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>MessagesScreen(api,identifier(i['id'])))))));
}
class MessagesScreen extends StatefulWidget {const MessagesScreen(this.api,this.id,{super.key});final CircleApi api;final int id;@override State<MessagesScreen> createState()=>_MessagesScreenState();}
class _MessagesScreenState extends State<MessagesScreen> {
  final text=TextEditingController();int? reply; late Future<List<Map<String,dynamic>>> future;
  @override void initState(){super.initState();refresh();}
  void refresh()=>setState(()=>future=widget.api.call('messages',query:{'conversation_id':'${widget.id}'}).then(items));
  Future<void> send() async {if(text.text.trim().isEmpty)return;try {await widget.api.call('messages',query:{'conversation_id':'${widget.id}'},body:{'body':text.text.trim(),'reply_to_id':reply??0});text.clear();reply=null;refresh();}catch(e){if(mounted)notify(context,'$e');}}
  Future<void> attach() async {final p=await FilePicker.platform.pickFiles();if(p==null||p.files.single.path==null)return;
    try{await widget.api.upload('message-upload',File(p.files.single.path!),query:{'conversation_id':'${widget.id}'},fields:{'kind':'FILE'});refresh();}catch(e){if(mounted)notify(context,'$e');}}
  @override void dispose(){text.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('Диалог #${widget.id}'),actions:[IconButton(onPressed:refresh,icon:const Icon(Icons.refresh))]),body:Column(children:[
    Expanded(child:FutureBuilder<List<Map<String,dynamic>>>(future:future,builder:(c,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return ListView(padding:const EdgeInsets.all(12),children:[for(final m in s.data!)Card(child:ListTile(
      title:Text('${m['body']??''}'),subtitle:Text('${m['created_at']??''}${m['reply_body']!=null?' · ↳ ${m['reply_body']}':''}'),
      trailing:PopupMenuButton<String>(onSelected:(value)async {if(value=='reply'){setState(()=>reply=identifier(m['id']));return;}
        try{await widget.api.call('message-reaction',body:{'conversation_id':widget.id,'message_id':identifier(m['id']),'emoji':value});refresh();}catch(e){if(context.mounted)notify(context,'$e');}},
        itemBuilder:(_)=>[const PopupMenuItem(value:'reply',child:Text('Ответить')),...['❤️','👍','😂','🔥'].map((e)=>PopupMenuItem(value:e,child:Text(e)))])))]); })),
    if(reply!=null)ListTile(title:Text('Ответ на #$reply'),trailing:IconButton(onPressed:()=>setState(()=>reply=null),icon:const Icon(Icons.close))),
    Padding(padding:const EdgeInsets.all(12),child:Row(children:[IconButton(tooltip:'Вложение',onPressed:attach,icon:const Icon(Icons.attach_file)),Expanded(child:TextField(controller:text,maxLines:3,minLines:1,onSubmitted:(_)=>send(),decoration:const InputDecoration(hintText:'Сообщение'))),IconButton(onPressed:send,icon:const Icon(Icons.send,color:gold))]))]));
}
class CommunitiesScreen extends StatelessWidget {const CommunitiesScreen(this.api,{super.key});final CircleApi api;
  @override Widget build(BuildContext context)=>ApiList(api:api,route:'communities',itemBuilder:(c,i,r)=>Card(child:ListTile(title:Text('${i['name']}'),subtitle:Text('${i['description']??''}'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>CommunityScreen(api,identifier(i['id'])))))));
}
class CommunityScreen extends StatefulWidget {const CommunityScreen(this.api,this.id,{super.key});final CircleApi api;final int id;@override State<CommunityScreen> createState()=>_CommunityScreenState();}
class _CommunityScreenState extends State<CommunityScreen>{
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Сообщество')),body:FutureBuilder<Map<String,dynamic>>(future:widget.api.call('community',query:{'id':'${widget.id}'}),builder:(c,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());
 final community=obj(s.data!['community']);final channels=(community['channels'] as List? ?? []);
 return ListView(children:[ListTile(title:Text('${community['name']??''}'),subtitle:Text('${community['description']??''}')),
  const Padding(padding:EdgeInsets.all(12),child:Text('Каналы',style:TextStyle(color:gold,fontSize:20))),
  for(final v in channels)ListTile(leading:const Icon(Icons.tag),title:Text('${v['name']}'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ChannelScreen(widget.api,identifier(v['id']))))),
  const Padding(padding:EdgeInsets.all(12),child:Text('Публикации',style:TextStyle(color:gold,fontSize:20))),SizedBox(height:600,child:FeedScreen(widget.api,route:'community-feed',query:{'id':'${widget.id}'}))]);}));
}
class ChannelScreen extends StatefulWidget {const ChannelScreen(this.api,this.id,{super.key});final CircleApi api;final int id;@override State<ChannelScreen> createState()=>_ChannelScreenState();}
class _ChannelScreenState extends State<ChannelScreen>{final text=TextEditingController();int count=0;@override void dispose(){text.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('Канал #${widget.id}')),body:Column(children:[Expanded(child:ApiList(key:ValueKey(count),api:widget.api,route:'channel-messages',query:{'channel_id':'${widget.id}'},itemBuilder:(c,i,r)=>ListTile(title:Text('${i['body']??''}'),subtitle:Text('${i['created_at']??''}')))),Row(children:[Expanded(child:TextField(controller:text,decoration:const InputDecoration(hintText:'Написать в канал'))),IconButton(onPressed:()async{try{await widget.api.call('channel-send',body:{'channel_id':widget.id,'body':text.text});text.clear();setState(()=>count++);}catch(e){if(context.mounted)notify(context,'$e');}},icon:const Icon(Icons.send))]) ]));
}
class NotificationsScreen extends StatelessWidget {const NotificationsScreen(this.api,{super.key});final CircleApi api;
 @override Widget build(BuildContext context)=>Column(children:[Padding(padding:const EdgeInsets.all(10),child:FilledButton(onPressed:()async{try{await api.call('notification-read',body:{'id':0});if(context.mounted)notify(context,'Отмечено прочитанным');}catch(e){if(context.mounted)notify(context,'$e');}},child:const Text('Прочитать все'))),Expanded(child:ApiList(api:api,route:'notifications',itemBuilder:(c,i,r)=>Card(child:ListTile(leading:Icon(i['read']==true?Icons.notifications_none:Icons.notifications_active,color:gold),title:Text('${i['actor_name']??'Circle'} · ${i['kind']??''}'),subtitle:Text('${i['created_at']??''}'),onTap:()async{try{await api.call('notification-read',body:{'id':identifier(i['id'])});r();}catch(e){if(c.mounted)notify(c,'$e');}}))))]);
}
class CallsScreen extends StatelessWidget {const CallsScreen(this.api,{super.key});final CircleApi api;
 @override Widget build(BuildContext context)=>ApiList(api:api,route:'mobile-call-history',itemBuilder:(c,i,r)=>Card(child:ListTile(leading:Icon(i['direction']=='incoming'?Icons.call_received:Icons.call_made),title:Text(label(obj(i['peer']))),subtitle:Text('${i['status']??''} · ${i['created_at']??''}'))));
}

class UpdatesScreen extends StatefulWidget {const UpdatesScreen({super.key});@override State<UpdatesScreen> createState()=>_UpdatesScreenState();}
class _UpdatesScreenState extends State<UpdatesScreen> {
  String status='Проверка обновлений не выполнялась'; bool busy=false;
  Future<void> check() async {
    if(updateManifest.isEmpty||updatePublicKey.isEmpty){setState(()=>status='Канал обновлений не настроен. Укажите CIRCLE_UPDATE_URL и CIRCLE_UPDATE_PUBLIC_KEY при сборке.');return;}
    setState((){busy=true;status='Проверяю цифровую подпись обновления...';});
    final updater=CircleUpdater(manifestUrl:Uri.parse(updateManifest), publicKeyBase64:updatePublicKey);
    try {
      final release=await updater.check(appVersion);
      if(release==null){if(mounted)setState(()=>status='Установлена актуальная версия $appVersion');return;}
      if(!mounted)return;
      final consent=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text('Обновление ${release.version}'),content:const Text('Скачать и проверить установщик? Перед запуском закройте Circle.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Позже')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Скачать'))]));
      if(consent!=true)return;
      if(mounted)setState(()=>status='Скачиваю и проверяю SHA-256...');
      final file=await updater.downloadVerified(release);
      if(mounted)setState(()=>status='Файл проверен: ${file.path}');
      if(!mounted)return;
      final launch=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Установщик готов'),content:const Text('Запустить обновление? Дождитесь закрытия Circle перед установкой.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Позже')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Запустить'))]));
      if(launch==true){await Process.start(file.path,[],mode:ProcessStartMode.detached);await windowManager.close();}
    }catch(e){if(mounted)setState(()=>status='Ошибка: $e');}finally{updater.close();if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:650),child:Card(child:Padding(padding:const EdgeInsets.all(30),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.system_update,size:55,color:gold),const SizedBox(height:12),const Text('Circle Windows',style:TextStyle(fontSize:25)),const Text('Версия $appVersion'),const SizedBox(height:18),Text(status,textAlign:TextAlign.center),const SizedBox(height:18),FilledButton(onPressed:busy?null:check,child:Text(busy?'Проверяю...':'Проверить обновления'))])))));
}

class StoriesStrip extends StatefulWidget {const StoriesStrip(this.api,{super.key});final CircleApi api;@override State<StoriesStrip> createState()=>_StoriesStripState();}
class _StoriesStripState extends State<StoriesStrip>{
  @override Widget build(BuildContext context){final api=widget.api;
    return FutureBuilder<Map<String,dynamic>>(future:api.call('stories'),builder:(c,s)=>Row(children:[
      Padding(padding:const EdgeInsets.all(8),child:OutlinedButton.icon(icon:const Icon(Icons.add_circle_outline),label:const Text('История'),onPressed:()async {
        final file=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['jpg','jpeg','png','webp','gif','mp4','webm']);if(file==null||file.files.single.path==null)return;
        if(!context.mounted)return;final caption=await compose(context,'Подпись к истории');if(caption==null)return;
        try{await api.upload('story-create',File(file.files.single.path!),field:'media',fields:{'caption':caption});if(mounted)setState((){});}catch(e){if(context.mounted)notify(context,'$e');}
      })),
      Expanded(child:s.hasError?Text('${s.error}'):s.hasData?ListView(scrollDirection:Axis.horizontal,children:[for(final story in items(s.data!))
        Padding(padding:const EdgeInsets.all(5),child:ActionChip(label:Text(label(obj(story['author']))),onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>StoryViewer(api,story)))))]):const Center(child:CircularProgressIndicator()))]));
  }
}
class StoryViewer extends StatelessWidget {const StoryViewer(this.api,this.story,{super.key});final CircleApi api;final Map<String,dynamic> story;
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(label(obj(story['author'])))),body:Center(child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
    if('${story['media_mime']}'.startsWith('image/'))FutureBuilder<List<int>>(future:api.media('story-media',identifier(story['id'])),builder:(c,s)=>s.hasData?SizedBox(height:400,child:Image.memory(Uint8List.fromList(s.data!),fit:BoxFit.contain)):Text('${s.error??'Загрузка...'}')),
    if(!'${story['media_mime']}'.startsWith('image/'))const Text('Просмотр видеоисторий требует подключения видеоплеера'),
    Text('${story['caption']??''}')])));
}
