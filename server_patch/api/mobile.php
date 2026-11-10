<?php
declare(strict_types=1);
// Circle Mobile API 1.0 alpha. HTTPS-only, same database as web, device-revocable tokens.
require dirname(__DIR__) . '/app/bootstrap.php';
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, private');
header('X-Content-Type-Options: nosniff');
// Intentionally no CORS allow-origin header: the mobile client is native, not a browser.

function mobile_reply(array $payload, int $status=200): never {
    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}
function mobile_fail(string $code, int $status): never { mobile_reply(['ok'=>false,'error'=>$code],$status); }
function mobile_json(): array {
    if (!str_starts_with(strtolower(trim(explode(';', (string)($_SERVER['CONTENT_TYPE']??''))[0])), 'application/json')) mobile_fail('JSON_REQUIRED',415);
    $raw=file_get_contents('php://input',false,null,0,16001);
    if($raw===false||strlen($raw)>16000) mobile_fail('PAYLOAD_TOO_LARGE',413);
    $value=json_decode($raw,true);
    if(!is_array($value)||array_is_list($value))mobile_fail('INVALID_JSON',400);
    return $value;
}
function mobile_token_hash(string $token): string {return hash_hmac('sha256',$token,setting('app_key'));}
function mobile_auth(): array {
    $header=(string)($_SERVER['HTTP_AUTHORIZATION']??$_SERVER['REDIRECT_HTTP_AUTHORIZATION']??'');
    if(!preg_match('/^Bearer\s+([a-f0-9]{64})$/i',$header,$match))mobile_fail('UNAUTHORIZED',401);
    $q=db()->prepare('SELECT t.id AS token_id,u.id,u.username,u.email,u.platform_role,p.display_name,p.avatar_path FROM mobile_access_tokens t JOIN users u ON u.id=t.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE t.token_hash=? AND t.revoked_at IS NULL AND t.expires_at>NOW() LIMIT 1');
    $q->execute([mobile_token_hash(strtolower($match[1]))]);$u=$q->fetch();
    if(!$u)mobile_fail('UNAUTHORIZED',401);
    if(circle_trust_suspended((int)$u['id']))mobile_fail('ACCOUNT_SUSPENDED',403);
    db()->prepare('UPDATE mobile_access_tokens SET last_used_at=NOW(),expires_at=DATE_ADD(NOW(),INTERVAL 180 DAY) WHERE id=? AND (last_used_at IS NULL OR last_used_at<DATE_SUB(NOW(), INTERVAL 1 DAY))')->execute([(int)$u['token_id']]);
    return $u;
}
function mobile_profile(array $row): array {
    $id=(int)$row['id'];
    return ['id'=>$id,'username'=>(string)$row['username'],'display_name'=>(string)($row['display_name']?:$row['username']),
        'avatar_url'=>!empty($row['avatar_path'])?'/api/mobile.php?route=avatar&id='.$id:null,
        'verified'=>!empty($row['verified']),'platform_role'=>$row['platform_role']??'USER'];
}
/** Safe optional decorations: incomplete legacy migrations must not hide basic user pages. */
function mobile_profile_optional(int $userId): array {
    $empty=['frame'=>'','status'=>'','verified'=>false,'admin'=>false];
    try {return circle_reward_data($userId);}
    catch (Throwable $error) {
        error_log('Circle Mobile API optional profile reward: '.$error->getMessage());
        return $empty;
    }
}
function mobile_is_verified(int $userId): bool {
    try {
        $q=db()->prepare('SELECT 1 FROM circle_verified_profiles WHERE user_id=? LIMIT 1');
        $q->execute([$userId]);return (bool)$q->fetchColumn();
    } catch (Throwable $error) {
        error_log('Circle Mobile API optional verified: '.$error->getMessage());return false;
    }
}
function mobile_reward_statuses_safe(): array {
    try { return circle_reward_statuses(); }
    catch (Throwable $error) {
        error_log('Circle Mobile API optional reward statuses: '.$error->getMessage());
        return [];
    }
}
function mobile_verified_map(array $rows): array {
    $ids=array_values(array_unique(array_filter(array_map('intval',array_column($rows,'id')))));
    if(!$ids)return [];
    $out=[];
    try {
        $marks=implode(',',array_fill(0,count($ids),'?'));
        $q=db()->prepare('SELECT user_id FROM circle_verified_profiles WHERE user_id IN ('.$marks.')');
        $q->execute($ids);foreach($q->fetchAll(PDO::FETCH_COLUMN) as $id)$out[(int)$id]=true;
    }catch(Throwable $error){error_log('Circle Mobile API verification lookup: '.$error->getMessage());}
    return $out;
}
function mobile_limiter_key(): string {return hash_hmac('sha256',(string)($_SERVER['REMOTE_ADDR']??'unknown'),setting('app_key'));}
function mobile_limited(string $hash): bool {
    $q=db()->prepare('SELECT COUNT(*) FROM login_attempts WHERE ip_hash=? AND attempted_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)');
    $q->execute([$hash]);return (int)$q->fetchColumn()>=10;
}
function mobile_failed_login(string $hash): void {db()->prepare('INSERT INTO login_attempts(ip_hash,attempted_at) VALUES(?,NOW())')->execute([$hash]);}
function mobile_method(string $wanted): void {if(($_SERVER['REQUEST_METHOD']??'')!==$wanted)mobile_fail('METHOD_NOT_ALLOWED',405);}

/** Only a member of a two-person DM can read/write attachments. */
function mobile_dm_access(int $conversationId,int $uid): void {
    if($conversationId<1)mobile_fail('INVALID_CONVERSATION',400);
    $q=db()->prepare('SELECT COUNT(*) FROM dm_members WHERE conversation_id=? AND user_id=?');
    $q->execute([$conversationId,$uid]);if((int)$q->fetchColumn()!==1)mobile_fail('FORBIDDEN',403);
    $q=db()->prepare('SELECT COUNT(*) FROM dm_members WHERE conversation_id=?');
    $q->execute([$conversationId]);if((int)$q->fetchColumn()!==2)mobile_fail('UNSUPPORTED_CONVERSATION',422);
}
function mobile_mark_dm_read(int $conversationId,int $uid,int $lastId): void {
    if($lastId<=0)return;
    db()->prepare('INSERT INTO dm_read_states(conversation_id,user_id,last_read_message_id,read_at) VALUES(?,?,?,NOW()) ON DUPLICATE KEY UPDATE last_read_message_id=GREATEST(last_read_message_id,VALUES(last_read_message_id)),read_at=NOW()')->execute([$conversationId,$uid,$lastId]);
    db()->prepare("UPDATE notifications SET read_at=NOW() WHERE user_id=? AND read_at IS NULL AND kind='dm_message' AND JSON_UNQUOTE(JSON_EXTRACT(payload,'$.conversation_id'))=CAST(? AS CHAR)")->execute([$uid,$conversationId]);
}
function mobile_attachment_rows(array $messages): array {
    if(!$messages)return $messages;
    $ids=array_map(static fn($m)=>(int)$m['id'],$messages);
    $marks=implode(',',array_fill(0,count($ids),'?'));
    $q=db()->prepare('SELECT id,message_id,original_name,mime_type,file_size,kind FROM dm_attachments WHERE message_id IN ('.$marks.') ORDER BY id');
    $q->execute($ids);$byId=[];
    foreach($q->fetchAll() as $a){$mid=(int)$a['message_id'];$byId[$mid][]=[
      'id'=>(int)$a['id'],'name'=>(string)$a['original_name'],'mime'=>(string)$a['mime_type'],
      'size'=>(int)$a['file_size'],'kind'=>(string)$a['kind']];}
    // Batch-load reactions rather than running one query per message.
    $reactions=db()->prepare('SELECT message_id,emoji,COUNT(*) AS total,MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM dm_message_reactions WHERE message_id IN ('.$marks.') GROUP BY message_id,emoji');
    $me=(int)($GLOBALS['circle_mobile_actor_id']??0);
    $reactions->execute(array_merge([$me],$ids));$reactById=[];
    foreach($reactions->fetchAll() as $r)$reactById[(int)$r['message_id']][]=['emoji'=>$r['emoji'],'total'=>(int)$r['total'],'mine'=>(bool)$r['mine']];
    foreach($messages as &$m){$m['id']=(int)$m['id'];$m['user_id']=(int)$m['user_id'];$m['attachments']=$byId[$m['id']]??[];$m['reactions']=$reactById[$m['id']]??[];}
    unset($m);return $messages;
}
/** Server-enforced channel access, including community bans and roles. */
function mobile_channel_access(int $channelId,int $uid,bool $write=false): array {
    if($channelId<1)mobile_fail('INVALID_CHANNEL',400);
    $q=db()->prepare('SELECT ch.id,ch.community_id,ch.slowmode_seconds FROM channels ch JOIN community_members cm ON cm.community_id=ch.community_id AND cm.user_id=? WHERE ch.id=? LIMIT 1');
    $q->execute([$uid,$channelId]);$row=$q->fetch();if(!$row)mobile_fail('FORBIDDEN',403);
    $ban=db()->prepare('SELECT 1 FROM community_bans WHERE community_id=? AND user_id=? AND (expires_at IS NULL OR expires_at>NOW()) LIMIT 1');
    $ban->execute([(int)$row['community_id'],$uid]);if($ban->fetchColumn())mobile_fail('COMMUNITY_BANNED',403);
    if($write&&!has_community_permission((int)$row['community_id'],$uid,'SEND_MESSAGES'))mobile_fail('FORBIDDEN',403);
    return $row;
}
/** Only microphone publication is permitted in mobile voice channels. */
function mobile_voice_token(array $user,string $room): string {
    $key=setting('livekit_api_key');$secret=setting('livekit_api_secret');
    if(!$key||!$secret||!preg_match('/^[A-Za-z0-9_-]{1,80}$/D',$room))throw new RuntimeException('LiveKit unavailable');
    $now=time();$head=b64url(json_encode(['alg'=>'HS256','typ'=>'JWT']));
    $claims=['iss'=>$key,'sub'=>'user-'.$user['id'].'-'.bin2hex(random_bytes(4)),
      'name'=>(string)$user['username'],'nbf'=>$now-5,'iat'=>$now,'exp'=>$now+120,
      'video'=>['roomJoin'=>true,'room'=>$room,'canPublish'=>true,'canSubscribe'=>true,'canPublishData'=>false,'canPublishSources'=>['microphone']]];
    $body=b64url(json_encode($claims,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));
    return $head.'.'.$body.'.'.b64url(hash_hmac('sha256',$head.'.'.$body,$secret,true));
}
/** A mobile-origin call has its own durable state, independent of read notifications. */
function mobile_call_expire(): void {
    circle_private_call_expire();
}
function mobile_call_record(int $id,int $uid): array {
    $q=db()->prepare('SELECT * FROM mobile_private_calls WHERE id=? AND (caller_id=? OR callee_id=?) LIMIT 1');
    $q->execute([$id,$uid,$uid]);$call=$q->fetch(PDO::FETCH_ASSOC);
    if(!$call)mobile_fail('CALL_NOT_FOUND',404);
    mobile_dm_access((int)$call['conversation_id'],$uid);
    return $call;
}
function mobile_call_history(int $uid): array {
    $q=db()->prepare("SELECT c.id,c.conversation_id,c.caller_id,c.callee_id,c.status,c.created_at,c.answered_at,c.ended_at,u.username,p.display_name,p.avatar_path FROM mobile_private_calls c JOIN users u ON u.id=IF(c.caller_id=?,c.callee_id,c.caller_id) LEFT JOIN user_profiles p ON p.user_id=u.id WHERE c.caller_id=? OR c.callee_id=? ORDER BY c.id DESC LIMIT 50");
    $q->execute([$uid,$uid,$uid]);$items=[];
    foreach($q->fetchAll() as $r){$items[]=['id'=>(int)$r['id'],'conversation_id'=>(int)$r['conversation_id'],'direction'=>((int)$r['caller_id']===$uid?'outgoing':'incoming'),'status'=>$r['status'],'created_at'=>$r['created_at'],'answered_at'=>$r['answered_at'],'ended_at'=>$r['ended_at'],'peer'=>mobile_profile(['id'=>((int)$r['caller_id']===$uid?(int)$r['callee_id']:(int)$r['caller_id']),'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])];}
    return $items;
}
/** Local copy of the voice signature detector: mobile.php does not load index.php. */
function mobile_detect_voice_mime(string $path,string $reported=''): ?string {
    $fp=@fopen($path,'rb');if(!$fp)return null;$head=(string)fread($fp,32);fclose($fp);
    if(str_starts_with($head,"\x1A\x45\xDF\xA3"))return 'audio/webm';
    if(str_starts_with($head,'OggS'))return 'audio/ogg';
    if(strlen($head)>=12&&substr($head,4,4)==='ftyp')return 'audio/mp4';
    if(strlen($head)>=12&&substr($head,0,4)==='RIFF'&&substr($head,8,4)==='WAVE')return 'audio/wav';
    if(str_starts_with($head,'ID3')||(strlen($head)>=2&&ord($head[0])===255&&(ord($head[1])&224)===224))return 'audio/mpeg';
    $types=['audio/webm'=>'audio/webm','video/webm'=>'audio/webm','audio/ogg'=>'audio/ogg','application/ogg'=>'audio/ogg','audio/mp4'=>'audio/mp4','audio/mpeg'=>'audio/mpeg','audio/wav'=>'audio/wav','audio/x-wav'=>'audio/wav'];
    return $types[strtolower(trim($reported))]??null;
}
/** Authenticated binary endpoint: neither file paths nor session cookies are exposed. */
function mobile_send_attachment(array $a): never {
    $path=dirname(__DIR__).'/uploads/messages/'.(string)$a['stored_name'];
    if(!preg_match('/^[a-f0-9]{40}\.[a-z0-9]{2,5}$/',(string)$a['stored_name'])||!is_file($path))mobile_fail('NOT_FOUND',404);
    $mime=(string)$a['mime_type'];
    $actual=(new finfo(FILEINFO_MIME_TYPE))->file($path);
    $voice=(string)$a['kind']==='VOICE';
    if($voice){
        $recognized=mobile_detect_voice_mime($path,$actual);
        if(!in_array($recognized,['audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav'],true))mobile_fail('UNSUPPORTED_MEDIA',415);
        $mime=$recognized;
    }else{
        if(!in_array($mime,['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'],true)||$actual!==$mime)mobile_fail('UNSUPPORTED_MEDIA',415);
    }
    $size=filesize($path);if($size===false||$size<1)mobile_fail('NOT_FOUND',404);
    $start=0;$end=$size-1;
    header('Content-Type: '.$mime);header('Cache-Control: private, '.(str_starts_with($mime,'image/')?'max-age=60':'no-store'));header('Vary: Authorization');header('X-Content-Type-Options: nosniff');
    header('Content-Disposition: inline; filename="media"');header('Accept-Ranges: bytes');
    header("Content-Security-Policy: default-src 'none'; sandbox");
    if(isset($_SERVER['HTTP_RANGE'])){
        $range=(string)$_SERVER['HTTP_RANGE'];
        if(!preg_match('/^bytes=(\d*)-(\d*)$/',$range,$r)||($r[1]===''&&$r[2]==='')){header('Content-Range: bytes */'.$size);mobile_fail('INVALID_RANGE',416);}
        if($r[1]===''){$count=(int)$r[2];if($count<=0){header('Content-Range: bytes */'.$size);mobile_fail('INVALID_RANGE',416);}$start=max(0,$size-$count);}
        else{$start=(int)$r[1];if($r[2]!=='')$end=min($end,(int)$r[2]);}
        if($start>=$size||$start>$end){header('Content-Range: bytes */'.$size);mobile_fail('INVALID_RANGE',416);}
        http_response_code(206);header('Content-Range: bytes '.$start.'-'.$end.'/'.$size);
    }
    header('Content-Length: '.($end-$start+1));
    $fp=fopen($path,'rb');if(!$fp)exit;fseek($fp,$start);$left=$end-$start+1;
    while($left>0&&!feof($fp)){$chunk=fread($fp,min($left,65536));if($chunk===false||$chunk==='')break;echo $chunk;$left-=strlen($chunk);}
    fclose($fp);exit;
}


/** Enforce the same visibility boundaries as Circle web post renderer. */
function mobile_post_access(int $postId,int $uid): array {
    $q=db()->prepare('SELECT * FROM social_posts WHERE id=? LIMIT 1');$q->execute([$postId]);$p=$q->fetch();
    if(!$p)mobile_fail('POST_NOT_FOUND',404);
    if((int)$p['author_id']===$uid)return $p;
    if($p['scope_type']==='GROUP'){
        $m=db()->prepare('SELECT 1 FROM community_members WHERE community_id=? AND user_id=? LIMIT 1');$m->execute([(int)$p['community_id'],$uid]);
        if(!$m->fetchColumn())mobile_fail('FORBIDDEN',403);
        $ban=db()->prepare('SELECT 1 FROM community_bans WHERE community_id=? AND user_id=? AND (expires_at IS NULL OR expires_at>NOW()) LIMIT 1');
        $ban->execute([(int)$p['community_id'],$uid]);if($ban->fetchColumn())mobile_fail('COMMUNITY_BANNED',403);
    }elseif($p['visibility']!=='PUBLIC'){
        $m=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");
        $m->execute([$uid,(int)$p['author_id'],(int)$p['author_id'],$uid]);
        if(!$m->fetchColumn())mobile_fail('FORBIDDEN',403);
    }
    return $p;
}
function mobile_social_media(string $stored,string $mime): never {
    if(!preg_match('/^[a-f0-9]{48}\.(?:jpg|png|webp|gif|mp4|webm)$/',$stored))mobile_fail('NOT_FOUND',404);
    $path=storage_dir().'/circle-media/'.$stored;
    if(!is_file($path)||is_link($path))mobile_fail('NOT_FOUND',404);
    $actual=(new finfo(FILEINFO_MIME_TYPE))->file($path);
    if($actual!==$mime || !in_array($actual,['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm'],true))mobile_fail('UNSUPPORTED_MEDIA',415);
    $size=filesize($path);$start=0;$end=$size-1;
    header('Content-Type: '.$actual);header('X-Content-Type-Options: nosniff');header('Content-Disposition: inline; filename="circle-media"');
    header("Content-Security-Policy: default-src 'none'; sandbox");header('Cache-Control: private, '.(str_starts_with($actual,'image/')?'max-age=60':'no-store'));header('Vary: Authorization');header('Accept-Ranges: bytes');
    $range=(string)($_SERVER['HTTP_RANGE']??'');
    if($range!==''){
        if(!preg_match('/^bytes=(\d*)-(\d*)$/D',$range,$match)||($match[1]===''&&$match[2]==='')){header('Content-Range: bytes */'.$size);http_response_code(416);exit;}
        if($match[1]===''){$suffix=(int)$match[2];if($suffix<1){header('Content-Range: bytes */'.$size);http_response_code(416);exit;}$start=max(0,$size-$suffix);}
        else {$start=(int)$match[1];$end=$match[2]===''?$end:min($end,(int)$match[2]);}
        if($start>=$size||$end<$start){header('Content-Range: bytes */'.$size);http_response_code(416);exit;}
        http_response_code(206);header('Content-Range: bytes '.$start.'-'.$end.'/'.$size);
    }
    header('Content-Length: '.($end-$start+1));
    $handle=fopen($path,'rb');if($handle===false)mobile_fail('MEDIA_ERROR',500);
    fseek($handle,$start);$left=$end-$start+1;
    while($left>0&&!feof($handle)&&!connection_aborted()){$chunk=fread($handle,min($left,65536));if($chunk===false||$chunk==='')break;echo $chunk;$left-=strlen($chunk);}
    fclose($handle);exit;
}
/** Batch feed stats: two aggregate queries for up to 40 visible cards. */
function mobile_post_stats_bulk(array $ids,int $uid): array {
    $ids=array_values(array_unique(array_filter(array_map('intval',$ids),static fn($id)=>$id>0)));
    if(!$ids)return [];
    $marks=implode(',',array_fill(0,count($ids),'?'));
    $stats=[];foreach($ids as $id)$stats[$id]=['likes'=>0,'comments'=>0,'liked'=>false,'reposts'=>0,'reposted'=>false];
    $q=db()->prepare("SELECT post_id,COUNT(*) AS total,MAX(user_id=?) AS mine FROM social_post_reactions WHERE reaction='LIKE' AND post_id IN ($marks) GROUP BY post_id");
    $q->execute(array_merge([$uid],$ids));foreach($q->fetchAll() as $r){$id=(int)$r['post_id'];$stats[$id]['likes']=(int)$r['total'];$stats[$id]['liked']=(bool)$r['mine'];}
    $q=db()->prepare("SELECT post_id,COUNT(*) AS total FROM social_post_comments WHERE post_id IN ($marks) GROUP BY post_id");
    $q->execute($ids);foreach($q->fetchAll() as $r)$stats[(int)$r['post_id']]['comments']=(int)$r['total'];
    $q=db()->prepare("SELECT post_id,COUNT(*) AS total,MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM social_post_reposts WHERE post_id IN ($marks) GROUP BY post_id");
    $q->execute(array_merge([$uid],$ids));foreach($q->fetchAll() as $r){$id=(int)$r['post_id'];$stats[$id]['reposts']=(int)$r['total'];$stats[$id]['reposted']=(bool)$r['mine'];}
    return $stats;
}
function mobile_post_stats(int $id,int $uid): array {
    $q=db()->prepare('SELECT (SELECT COUNT(*) FROM social_post_reactions WHERE post_id=? AND reaction=\'LIKE\') AS likes,(SELECT COUNT(*) FROM social_post_comments WHERE post_id=?) AS comments,EXISTS(SELECT 1 FROM social_post_reactions WHERE post_id=? AND user_id=? AND reaction=\'LIKE\') AS liked');
    $q->execute([$id,$id,$id,$uid]);$r=$q->fetch();return ['likes'=>(int)$r['likes'],'comments'=>(int)$r['comments'],'liked'=>(bool)$r['liked']];
}

// SSL termination on shared hosting: trust ONLY HTTPS reported by web server, never user-provided forwarded headers.
if((empty($_SERVER['HTTPS']) || $_SERVER['HTTPS']==='off') && (string)($_SERVER['SERVER_PORT']??'')!=='443') mobile_fail('HTTPS_REQUIRED',403);
$route=(string)($_GET['route']??'');
try {
    if($route==='health'){mobile_method('GET');mobile_reply(['ok'=>true,'product'=>'Circle Mobile API','api'=>'1.0-alpha']);}
    if($route==='register'){
        mobile_method('POST');$data=mobile_json();$ip=mobile_limiter_key();
        if(mobile_limited($ip))mobile_fail('RATE_LIMIT',429);
        $name=trim((string)($data['username']??''));$email=trim((string)($data['email']??''));
        $pass=(string)($data['password']??'');$display=trim((string)($data['display_name']??''));
        if(!preg_match('/^[A-Za-z0-9_]{3,24}$/D',$name)||!filter_var($email,FILTER_VALIDATE_EMAIL)||strlen($pass)<8||strlen($pass)>4096||mb_strlen($display)>60)mobile_fail('INVALID_REGISTRATION',422);
        if(feature_enabled('email-verification')&&!db_setting('smtp_host'))mobile_fail('MAIL_UNAVAILABLE',503);
        mobile_failed_login($ip); // Shared anonymous rate limiter limits repeated registrations.
        try{
            db()->beginTransaction();
            db()->prepare('INSERT INTO users(username,email,password_hash,email_verified_at,created_at) VALUES(?,?,?,?,NOW())')
                ->execute([$name,$email,password_hash($pass,PASSWORD_ARGON2ID),feature_enabled('email-verification')?null:date('Y-m-d H:i:s')]);
            $newId=(int)db()->lastInsertId();
            db()->prepare("INSERT INTO user_profiles(user_id,display_name,accent_color,layout_style,updated_at) VALUES(? ,?,'#C6A15B','EDITORIAL',NOW())")
                ->execute([$newId,$display]);
            db()->commit();
        }catch(PDOException $e){if(db()->inTransaction())db()->rollBack();if($e->getCode()==='23000')mobile_fail('ACCOUNT_EXISTS',409);throw $e;}
        if(feature_enabled('email-verification')){
            $token=bin2hex(random_bytes(32));db()->prepare("INSERT INTO account_email_tokens(user_id,token_hash,purpose,expires_at,created_at) VALUES(?,?,'VERIFY',DATE_ADD(NOW(),INTERVAL 24 HOUR),NOW())")
                ->execute([$newId,hash_hmac('sha256',$token,setting('app_key'))]);
            try{send_account_link($email,$token,'verify');}catch(Throwable $e){error_log('Circle mobile register: email unavailable');}
        }
        audit_event($newId,'mobile.registration');mobile_reply(['ok'=>true,'email_verification'=>feature_enabled('email-verification')]);
    }
    if($route==='forgot-password'){
        mobile_method('POST');$data=mobile_json();$email=trim((string)($data['email']??''));$hash=mobile_limiter_key();
        if(mobile_limited($hash))mobile_fail('RATE_LIMIT',429);
        mobile_failed_login($hash);
        if(filter_var($email,FILTER_VALIDATE_EMAIL)&&feature_enabled('password-reset')&&db_setting('smtp_host')){
            $q=db()->prepare('SELECT id FROM users WHERE email=?');$q->execute([$email]);$accountId=(int)$q->fetchColumn();
            if($accountId){
                $q=db()->prepare("SELECT COUNT(*) FROM account_email_tokens WHERE user_id=? AND purpose='RESET' AND created_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)");
                $q->execute([$accountId]);
                if((int)$q->fetchColumn()<3){
                    db()->prepare("UPDATE account_email_tokens SET used_at=NOW() WHERE user_id=? AND purpose='RESET' AND used_at IS NULL")->execute([$accountId]);
                    $token=bin2hex(random_bytes(32));
                    db()->prepare("INSERT INTO account_email_tokens(user_id,token_hash,purpose,expires_at,created_at) VALUES(?,?,'RESET',DATE_ADD(NOW(),INTERVAL 30 MINUTE),NOW())")
                        ->execute([$accountId,hash_hmac('sha256',$token,setting('app_key'))]);
                    try{send_account_link($email,$token,'reset');}catch(Throwable $e){error_log('Circle mobile password reset email unavailable');}
                }
            }
        }
        mobile_reply(['ok'=>true,'message'=>'Если аккаунт существует, письмо с восстановлением отправлено.']);
    }
    if($route==='password-reset'){
        mobile_method('POST');$data=mobile_json();$token=(string)($data['token']??'');$pass=(string)($data['password']??'');
        if(!preg_match('/^[a-f0-9]{64}$/D',$token)||strlen($pass)<8||strlen($pass)>4096)mobile_fail('INVALID_RESET',422);
        db()->beginTransaction();
        try{
            $hash=hash_hmac('sha256',$token,setting('app_key'));
            $q=db()->prepare("SELECT user_id FROM account_email_tokens WHERE token_hash=? AND purpose='RESET' AND expires_at>NOW() AND used_at IS NULL FOR UPDATE");
            $q->execute([$hash]);$accountId=(int)$q->fetchColumn();
            if(!$accountId){db()->rollBack();mobile_fail('INVALID_RESET',422);}
            db()->prepare('UPDATE account_email_tokens SET used_at=NOW() WHERE token_hash=?')->execute([$hash]);
            db()->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash($pass,PASSWORD_ARGON2ID),$accountId]);
            db()->prepare('UPDATE user_sessions SET revoked_at=NOW() WHERE user_id=? AND revoked_at IS NULL')->execute([$accountId]);
            db()->prepare('UPDATE mobile_access_tokens SET revoked_at=NOW() WHERE user_id=? AND revoked_at IS NULL')->execute([$accountId]);
            db()->prepare('DELETE FROM circle_remember_tokens WHERE user_id=?')->execute([$accountId]);
            db()->commit();audit_event($accountId,'mobile.password_reset');mobile_reply(['ok'=>true]);
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
    }
    if($route==='login'){
        mobile_method('POST');$data=mobile_json();$hash=mobile_limiter_key();
        if(mobile_limited($hash))mobile_fail('RATE_LIMIT',429);
        $login=trim((string)($data['login']??''));$pass=(string)($data['password']??'');$totp=trim((string)($data['totp_code']??''));
        if(strlen($login)<1||strlen($login)>190||strlen($pass)>512||strlen($totp)>30)mobile_fail('INVALID_CREDENTIALS',401);
        $q=db()->prepare('SELECT u.*,p.display_name,p.avatar_path FROM users u LEFT JOIN user_profiles p ON p.user_id=u.id WHERE u.email=? OR u.username=? LIMIT 1');
        $q->execute([$login,$login]);$row=$q->fetch();
        if(!$row||!password_verify($pass,(string)$row['password_hash'])){mobile_failed_login($hash);mobile_fail('INVALID_CREDENTIALS',401);}
        if(circle_trust_suspended((int)$row['id']))mobile_fail('ACCOUNT_SUSPENDED',403);
        if(feature_enabled('email-verification')&&empty($row['email_verified_at']))mobile_fail('VERIFY_EMAIL',403);
        if(!empty($row['totp_enabled'])){
            if(empty($row['totp_secret']))mobile_fail('TWO_FACTOR_UNAVAILABLE',403);
            if($totp==='')mobile_fail('TWO_FACTOR_REQUIRED',403);
            // TOTP only for mobile alpha. Recovery codes intentionally not consumed by this API.
            if(!totp_verify(decrypt_secret((string)$row['totp_secret']),$totp)){mobile_failed_login($hash);mobile_fail('INVALID_TWO_FACTOR',401);}
        }
        $token=bin2hex(random_bytes(32));$label=mb_substr(trim((string)($data['device']??'Circle Mobile')),0,120);
        if($label==='')$label='Circle Mobile';
        db()->prepare('INSERT INTO mobile_access_tokens(user_id,token_hash,device_label,created_at,expires_at) VALUES(?,?,?,NOW(),DATE_ADD(NOW(),INTERVAL 180 DAY))')->execute([(int)$row['id'],mobile_token_hash($token),$label]);
        audit_event((int)$row['id'],'mobile.login',['device'=>$label]);
        mobile_reply(['ok'=>true,'token'=>$token,'expires_in'=>15552000,'user'=>mobile_profile($row)]);
    }
    $actor=mobile_auth();$uid=(int)$actor['id'];$GLOBALS['circle_mobile_actor_id']=$uid;
    if($route==='brand'){
        mobile_method('GET');
        mobile_reply(['ok'=>true,'brand'=>['name'=>'Circle','tagline'=>'Твой круг. Твои люди.',
            'background'=>'#121316','surface'=>'#1D1E23','accent'=>'#C6A15B',
            'logo'=>'/assets/circle-mark.svg','locale'=>'ru']]);
    }
    if($route==='web-session-ticket'){
        mobile_method('POST');
        $count=db()->prepare('SELECT COUNT(*) FROM circle_mobile_web_tickets WHERE user_id=? AND created_at>DATE_SUB(NOW(),INTERVAL 1 MINUTE)');
        $count->execute([$uid]);if((int)$count->fetchColumn()>=8)mobile_fail('RATE_LIMIT',429);
        $ticket=bin2hex(random_bytes(32));
        db()->prepare('INSERT INTO circle_mobile_web_tickets(user_id,token_hash,expires_at,created_at) VALUES(?,?,DATE_ADD(NOW(),INTERVAL 45 SECOND),NOW())')->execute([$uid,hash('sha256',$ticket)]);
        mobile_reply(['ok'=>true,'ticket'=>$ticket,'url'=>'https://acircle.ru/?action=mobile-web-session']);
    }
    if(in_array($route,['profile-cover','community-icon','community-banner'],true)){
        mobile_method('GET');
        if($route==='profile-cover'){
            $target=(int)($_GET['id']??$uid);
            $q=db()->prepare('SELECT cover_path AS stored,visibility FROM user_profiles WHERE user_id=?');$q->execute([$target]);$row=$q->fetch();
            if($target!==$uid && ($row['visibility']??'PRIVATE')!=='PUBLIC'){
                $fq=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");
                $fq->execute([$uid,$target,$target,$uid]);if(!$fq->fetchColumn())mobile_fail('FORBIDDEN',403);
            }
            $base=storage_dir().'/circle-media/';
        }else{
            $id=(int)($_GET['id']??0);
            $col=$route==='community-icon'?'icon_path':'banner_path';
            $q=db()->prepare('SELECT c.'.$col.' AS stored FROM communities c JOIN community_members cm ON cm.community_id=c.id AND cm.user_id=? WHERE c.id=?');
            $q->execute([$uid,$id]);$row=$q->fetch();$base=storage_dir().'/circle-media/';
        }
        $stored=(string)($row['stored']??'');
        if(!preg_match('/^[a-f0-9]{32,48}\.(?:jpg|png|webp|gif)$/D',$stored))mobile_fail('NOT_FOUND',404);
        $file=$base.$stored;if(!is_file($file)||is_link($file))mobile_fail('NOT_FOUND',404);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($file);
        if(!in_array($mime,['image/jpeg','image/png','image/webp','image/gif'],true))mobile_fail('UNSUPPORTED_MEDIA',415);
        header('Content-Type: '.$mime);header('Content-Length: '.filesize($file));header('Cache-Control: private, max-age=300');readfile($file);exit;
    }
    if($route==='capabilities'){
        mobile_method('GET');mobile_reply(['ok'=>true,'api_version'=>'5.2.3-win-compat.2','features'=>[
            'profiles'=>feature_enabled('profiles'),'social_feed'=>feature_enabled('social-feed'),
            'voice_messages'=>feature_enabled('voice-messages'),
            'communities'=>feature_enabled('communities'),'stories'=>feature_enabled('stories'),
            'post_management'=>feature_enabled('social-feed'),'reposts'=>feature_enabled('post-interactions'),
            'profile_cover_upload'=>feature_enabled('profiles'),'conversation_open'=>feature_enabled('direct-messages')
        ]]);
    }
    if($route==='me'){mobile_method('GET');mobile_reply(['ok'=>true,'user'=>mobile_profile($actor)]);}
    if($route==='logout'){mobile_method('POST');db()->prepare('DELETE FROM mobile_push_devices WHERE mobile_token_id=?')->execute([(int)$actor['token_id']]);db()->prepare('UPDATE mobile_access_tokens SET revoked_at=NOW() WHERE id=?')->execute([(int)$actor['token_id']]);mobile_reply(['ok'=>true]);}

    if($route==='profile'){
        mobile_method('GET');if(!feature_enabled('profiles'))mobile_fail('FEATURE_DISABLED',403);
        $q=db()->prepare('SELECT u.id,u.username,p.display_name,p.avatar_path,p.cover_path,p.accent_color,p.bio,p.status_text,p.visibility FROM users u LEFT JOIN user_profiles p ON p.user_id=u.id WHERE u.id=? LIMIT 1');
        $q->execute([$uid]);$p=$q->fetch(PDO::FETCH_ASSOC);
        if(!$p)mobile_fail('NOT_FOUND',404);
        $p['verified']=mobile_is_verified($uid)?1:0;
        $reward=mobile_profile_optional($uid);
        $rewardName=(string)($reward['status']??'');
        $availableStatuses=mobile_reward_statuses_safe();
        mobile_reply(['ok'=>true,'user'=>mobile_profile($p),'cover_url'=>!empty($p['cover_path'])?'/api/mobile.php?route=profile-cover':null,'accent_color'=>(string)($p['accent_color']??'#C6A15B'),'bio'=>(string)($p['bio']??''),'status_text'=>(string)($p['status_text']??''),'visibility'=>(string)($p['visibility']??'PUBLIC'),
          'reward_frame'=>(string)($reward['frame']??''),'reward_status_key'=>$rewardName,
          'reward_status'=>$rewardName!==''?(string)($availableStatuses[$rewardName][0]??''):'' ]);
    }
    // Public profile view: never expose private biography, status or posts without access.
    if($route==='user-profile'){
        mobile_method('GET');if(!feature_enabled('profiles'))mobile_fail('FEATURE_DISABLED',403);
        $target=max(0,(int)($_GET['id']??0));if(!$target)mobile_fail('NOT_FOUND',404);
        $q=db()->prepare('SELECT u.id,u.username,p.display_name,p.avatar_path,p.cover_path,p.bio,p.status_text,p.visibility FROM users u LEFT JOIN user_profiles p ON p.user_id=u.id WHERE u.id=? LIMIT 1');$q->execute([$target]);$person=$q->fetch(PDO::FETCH_ASSOC);if(!$person)mobile_fail('NOT_FOUND',404);
        $person['verified']=mobile_is_verified($target)?1:0;
        $reward=mobile_profile_optional($target);
        $vis=(string)($person['visibility']??'PUBLIC');$allowed=$target===$uid||$vis==='PUBLIC';
        if(!$allowed){$f=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");$f->execute([$uid,$target,$target,$uid]);$allowed=(bool)$f->fetchColumn();}
        mobile_reply(['ok'=>true,'user'=>mobile_profile($person),'cover_url'=>$allowed&&!empty($person['cover_path'])?'/api/mobile.php?route=profile-cover&id='.$target:null,
            'status_text'=>$allowed?(string)($person['status_text']??''):'','bio'=>$allowed?(string)($person['bio']??''):'',
            'visibility'=>$vis,'can_view_posts'=>$allowed,
          'reward_status'=>$allowed?(string)(mobile_reward_statuses_safe()[(string)($reward['status']??'')][0]??''):'',
          'reward_frame'=>$allowed?(string)($reward['frame']??''):'']);
    }
    if($route==='profile-posts'){
        mobile_method('GET');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $target=(int)($_GET['user_id']??$uid);if($target<1)mobile_fail('INVALID_USER',422);$tab=(string)($_GET['tab']??'posts');
        if(!in_array($tab,['posts','reposts'],true))mobile_fail('INVALID_TAB',422);
        $profileQ=db()->prepare('SELECT visibility FROM user_profiles WHERE user_id=?');$profileQ->execute([$target]);$visibility=(string)($profileQ->fetchColumn()?:'PUBLIC');
        $view=$target===$uid||$visibility==='PUBLIC';
        if(!$view){$fq=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");$fq->execute([$uid,$target,$target,$uid]);$view=(bool)$fq->fetchColumn();}
        if(!$view)mobile_fail('FORBIDDEN',403);
        $fields='p.id,p.title,p.body,p.created_at,p.media_path,p.media_mime,p.comments_enabled,p.is_pinned,p.author_id,u.username,pr.display_name,pr.avatar_path';
        $joins=' JOIN users u ON u.id=p.author_id LEFT JOIN user_profiles pr ON pr.user_id=u.id ';
        if($tab==='reposts'){
            $sql="SELECT $fields FROM social_post_reposts rp JOIN social_posts p ON p.id=rp.post_id $joins WHERE rp.user_id=? AND
              (p.author_id=? OR (p.scope_type='GROUP' AND EXISTS(SELECT 1 FROM community_members cm WHERE cm.community_id=p.community_id AND cm.user_id=?)) OR
              (p.scope_type='USER' AND (p.visibility='PUBLIC' OR (p.visibility='FRIENDS' AND EXISTS(SELECT 1 FROM friendships f WHERE f.status='ACCEPTED' AND ((f.requester_id=? AND f.addressee_id=p.author_id) OR (f.addressee_id=? AND f.requester_id=p.author_id)))))))
              ORDER BY rp.created_at DESC LIMIT 40";
            $params=[$target,$uid,$uid,$uid,$uid];
        }else{
            $sql="SELECT $fields FROM social_posts p $joins WHERE p.scope_type='USER' AND p.author_id=? AND
              (p.author_id=? OR p.visibility='PUBLIC' OR (p.visibility='FRIENDS' AND EXISTS(SELECT 1 FROM friendships f WHERE f.status='ACCEPTED' AND ((f.requester_id=? AND f.addressee_id=p.author_id) OR (f.addressee_id=? AND f.requester_id=p.author_id)))))
              ORDER BY p.id DESC LIMIT 40";
            $params=[$target,$uid,$uid,$uid];
        }
        $q=db()->prepare($sql);$q->execute($params);$rows=$q->fetchAll();$stats=mobile_post_stats_bulk(array_column($rows,'id'),$uid);
        $authors=mobile_verified_map(array_map(static fn($r)=>['id'=>(int)$r['author_id']],$rows));$items=[];
        foreach($rows as $post){
            $id=(int)$post['id'];
            $author=mobile_profile(['id'=>$post['author_id'],'username'=>$post['username'],'display_name'=>$post['display_name'],'avatar_path'=>$post['avatar_path'],'verified'=>!empty($authors[(int)$post['author_id']])]);
            $items[]=['id'=>$id,'title'=>(string)$post['title'],'body'=>(string)$post['body'],'created_at'=>(string)$post['created_at'],'author'=>$author,'has_media'=>!empty($post['media_path']),'media_mime'=>$post['media_mime'],'comments_enabled'=>(bool)$post['comments_enabled'],'can_edit'=>(int)$post['author_id']===$uid,'is_pinned'=>!empty($post['is_pinned']),'stats'=>$stats[$id]];
        }
        mobile_reply(['ok'=>true,'items'=>$items,'tab'=>$tab]);
    }
    if($route==='reward-options'){
        mobile_method('GET');
        $earned=db()->prepare('SELECT achievement_key FROM circle_achievement_awards WHERE user_id=?');$earned->execute([$uid]);$awards=$earned->fetchAll(PDO::FETCH_COLUMN);
        $values=db()->prepare('SELECT frame_key,status_key FROM circle_user_rewards WHERE user_id=?');$values->execute([$uid]);$chosen=$values->fetch()?:[];
        $frames=[];foreach(circle_reward_frames() as $key=>$spec)if(in_array($key,$awards,true))$frames[]=['key'=>$key,'name'=>$spec[0]];
        $statuses=[];foreach(circle_reward_statuses() as $key=>$spec)if(in_array($key,$awards,true))$statuses[]=['key'=>$key,'name'=>$spec[0]];
        mobile_reply(['ok'=>true,'frames'=>$frames,'statuses'=>$statuses,'selected_frame'=>$chosen['frame_key']??'','selected_status'=>$chosen['status_key']??'']);
    }
    if($route==='reward-select'){
        mobile_method('POST');$d=mobile_json();$frame=(string)($d['frame']??'');$status=(string)($d['status']??'');
        if(($frame!==''&&!isset(circle_reward_frames()[$frame]))||($status!==''&&!isset(circle_reward_statuses()[$status])))mobile_fail('BAD_REWARD',422);
        $q=db()->prepare('SELECT achievement_key FROM circle_achievement_awards WHERE user_id=?');$q->execute([$uid]);$earned=$q->fetchAll(PDO::FETCH_COLUMN);
        if(($frame!==''&&!in_array($frame,$earned,true))||($status!==''&&!in_array($status,$earned,true)))mobile_fail('REWARD_NOT_EARNED',403);
        db()->prepare("INSERT INTO circle_user_rewards(user_id,frame_key,status_key,updated_at) VALUES(?,?,?,NOW()) ON DUPLICATE KEY UPDATE frame_key=VALUES(frame_key),status_key=VALUES(status_key),updated_at=NOW()")->execute([$uid,$frame,$status]);audit_event($uid,'profile.reward_selected');mobile_reply(['ok'=>true]);
    }
    if($route==='profile-save'){
        mobile_method('POST');if(!feature_enabled('profiles'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$name=trim((string)($d['display_name']??''));$bio=trim((string)($d['bio']??''));$status=trim((string)($d['status_text']??''));$visibility=(string)($d['visibility']??'PUBLIC');
        if($name===''||mb_strlen($name)>60||mb_strlen($bio)>500||mb_strlen($status)>80||!in_array($visibility,['PUBLIC','MEMBERS','PRIVATE'],true))mobile_fail('INVALID_PROFILE',422);
        db()->prepare('INSERT INTO user_profiles(user_id,display_name,bio,status_text,visibility,updated_at) VALUES(?,?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE display_name=VALUES(display_name),bio=VALUES(bio),status_text=VALUES(status_text),visibility=VALUES(visibility),updated_at=NOW()')->execute([$uid,$name,$bio,$status,$visibility]);
        audit_event($uid,'profile.updated');mobile_reply(['ok'=>true]);
    }
    if($route==='profile-cover-upload'){
        mobile_method('POST');if(!feature_enabled('profiles'))mobile_fail('FEATURE_DISABLED',403);
        $file=$_FILES['cover']??[];$tmp=(string)($file['tmp_name']??'');$size=(int)($file['size']??0);
        if(($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK||$size<1||$size>10*1024*1024||!is_uploaded_file($tmp))mobile_fail('INVALID_UPLOAD',422);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($tmp);$types=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp'];
        if(!isset($types[$mime])||!getimagesize($tmp))mobile_fail('UNSUPPORTED_MEDIA',415);
        $dir=storage_dir().'/circle-media';if(!is_dir($dir)&&!mkdir($dir,0700,true)&&!is_dir($dir))mobile_fail('STORAGE_ERROR',500);
        $name=bin2hex(random_bytes(24)).'.'.$types[$mime];if(!move_uploaded_file($tmp,$dir.'/'.$name))mobile_fail('UPLOAD_FAILED',500);
        try{db()->prepare('INSERT INTO user_profiles(user_id,cover_path,updated_at) VALUES(?,?,NOW()) ON DUPLICATE KEY UPDATE cover_path=VALUES(cover_path),updated_at=NOW()')->execute([$uid,$name]);}
        catch(Throwable $e){@unlink($dir.'/'.$name);throw $e;}
        try{audit_event($uid,'profile.cover_updated');}catch(Throwable $e){error_log('Circle mobile cover audit: '.$e->getMessage());}mobile_reply(['ok'=>true,'cover_url'=>'/api/mobile.php?route=profile-cover&id='.$uid]);
    }
    if($route==='avatar-upload'){
        mobile_method('POST');if(!feature_enabled('profiles'))mobile_fail('FEATURE_DISABLED',403);
        $file=$_FILES['avatar']??[];$size=(int)($file['size']??0);$tmp=(string)($file['tmp_name']??'');
        if(($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK||$size<1||$size>3*1024*1024||!is_uploaded_file($tmp))mobile_fail('INVALID_UPLOAD',422);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($tmp);$types=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp'];
        if(!isset($types[$mime])||!getimagesize($tmp))mobile_fail('UNSUPPORTED_MEDIA',415);
        $dir=storage_dir().'/avatars';if(!is_dir($dir)&&!mkdir($dir,0700,true)&&!is_dir($dir))mobile_fail('STORAGE_ERROR',500);
        $name=bin2hex(random_bytes(16)).'.'.$types[$mime];if(!move_uploaded_file($tmp,$dir.'/'.$name))mobile_fail('UPLOAD_FAILED',500);
        $q=db()->prepare('SELECT avatar_path FROM user_profiles WHERE user_id=?');$q->execute([$uid]);$previous=(string)$q->fetchColumn();
        try{db()->prepare('INSERT INTO user_profiles(user_id,avatar_path,updated_at) VALUES(?,?,NOW()) ON DUPLICATE KEY UPDATE avatar_path=VALUES(avatar_path),updated_at=NOW()')->execute([$uid,$name]);}
        catch(Throwable $e){@unlink($dir.'/'.$name);throw $e;}
        if(preg_match('/^[a-f0-9]{32}\.(?:jpg|png|webp)$/',$previous))@unlink($dir.'/'.$previous);
        audit_event($uid,'profile.avatar.updated');mobile_reply(['ok'=>true,'avatar_url'=>'/api/mobile.php?route=avatar&id='.$uid]);
    }
    if($route==='story-create'){
        mobile_method('POST');if(!feature_enabled('stories'))mobile_fail('FEATURE_DISABLED',403);
        $file=$_FILES['media']??[];$tmp=(string)($file['tmp_name']??'');$size=(int)($file['size']??0);$caption=trim((string)($_POST['caption']??''));
        if(mb_strlen($caption)>180||($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK||$size<1||$size>15*1024*1024||!is_uploaded_file($tmp))mobile_fail('INVALID_STORY',422);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($tmp);$types=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp','image/gif'=>'gif','video/mp4'=>'mp4','video/webm'=>'webm'];
        if(!isset($types[$mime])||(str_starts_with($mime,'image/')&&!getimagesize($tmp)))mobile_fail('UNSUPPORTED_MEDIA',415);
        $dir=storage_dir().'/circle-media';if(!is_dir($dir)&&!mkdir($dir,0700,true)&&!is_dir($dir))mobile_fail('STORAGE_ERROR',500);
        $name=bin2hex(random_bytes(24)).'.'.$types[$mime];if(!move_uploaded_file($tmp,$dir.'/'.$name))mobile_fail('UPLOAD_FAILED',500);
        try{db()->prepare('INSERT INTO social_stories(user_id,media_path,media_mime,caption,created_at,expires_at) VALUES(?,?,?,?,NOW(),DATE_ADD(NOW(),INTERVAL 24 HOUR))')->execute([$uid,$name,$mime,$caption]);}
        catch(Throwable $e){@unlink($dir.'/'.$name);throw $e;}
        mobile_reply(['ok'=>true,'story_id'=>(int)db()->lastInsertId()],201);
    }

    if($route==='avatar'){
        mobile_method('GET');$id=(int)($_GET['id']??0);if($id<1)mobile_fail('NOT_FOUND',404);
        $q=db()->prepare('SELECT p.avatar_path,p.visibility FROM user_profiles p WHERE p.user_id=?');$q->execute([$id]);$p=$q->fetch();
        if(!$p||!preg_match('/^[a-f0-9]{32}\.(jpg|png|webp)$/',(string)($p['avatar_path']??'')))mobile_fail('NOT_FOUND',404);
        $allowed=$id===$uid||$p['visibility']==='PUBLIC';
        if(!$allowed){$f=db()->prepare("SELECT 1 FROM friendships WHERE status IN ('ACCEPTED','PENDING') AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");$f->execute([$uid,$id,$id,$uid]);$allowed=(bool)$f->fetchColumn();}
        if(!$allowed)mobile_fail('FORBIDDEN',403);
        $file=storage_dir().'/avatars/'.$p['avatar_path'];if(!is_file($file))mobile_fail('NOT_FOUND',404);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($file);if(!in_array($mime,['image/jpeg','image/png','image/webp'],true))mobile_fail('NOT_FOUND',404);
        header('Content-Type: '.$mime);header('Content-Length: '.filesize($file));readfile($file);exit;
    }
    if($route==='attachment'){
        mobile_method('GET');$aid=(int)($_GET['id']??0);if($aid<1)mobile_fail('NOT_FOUND',404);
        $q=db()->prepare('SELECT a.* FROM dm_attachments a JOIN dm_messages m ON m.id=a.message_id JOIN dm_members dm ON dm.conversation_id=m.conversation_id AND dm.user_id=? WHERE a.id=? AND (SELECT COUNT(*) FROM dm_members x WHERE x.conversation_id=m.conversation_id)=2 LIMIT 1');
        $q->execute([$uid,$aid]);$a=$q->fetch();if(!$a)mobile_fail('NOT_FOUND',404);
        mobile_send_attachment($a);
    }
    // Circle Mobile 1.5 — community access is invite-only, mirroring the web flow.
    if($route==='communities'){
        mobile_method('GET');if(!feature_enabled('community-invites'))mobile_fail('FEATURE_DISABLED',403);
        $q=db()->prepare('SELECT c.id,c.name,c.description,c.slug,c.icon_path,c.banner_path,cm.member_role,(SELECT COUNT(*) FROM community_members x WHERE x.community_id=c.id) AS member_count FROM community_members cm JOIN communities c ON c.id=cm.community_id WHERE cm.user_id=? ORDER BY c.name LIMIT 200');
        $q->execute([$uid]);$items=[];
        foreach($q->fetchAll() as $row)$items[]=['id'=>(int)$row['id'],'name'=>$row['name'],'description'=>$row['description'],'slug'=>$row['slug'],'role'=>$row['member_role'],'icon_url'=>!empty($row['icon_path'])?'/api/mobile.php?route=community-icon&id='.$row['id']:null,'banner_url'=>!empty($row['banner_path'])?'/api/mobile.php?route=community-banner&id='.$row['id']:null,'members'=>(int)$row['member_count']];
        mobile_reply(['ok'=>true,'items'=>$items]);
    }
    if($route==='community'){
        mobile_method('GET');$id=max(0,(int)($_GET['id']??0));
        $q=db()->prepare('SELECT c.id,c.name,c.description,c.slug,c.news_enabled,c.icon_path,c.banner_path,c.accent_color,c.banner_zoom,c.banner_pos_x,c.banner_pos_y,cm.member_role FROM communities c JOIN community_members cm ON cm.community_id=c.id AND cm.user_id=? WHERE c.id=? LIMIT 1');$q->execute([$uid,$id]);$row=$q->fetch();if(!$row)mobile_fail('FORBIDDEN',403);
        $ch=db()->prepare('SELECT id,name FROM channels WHERE community_id=? ORDER BY id LIMIT 150');$ch->execute([$id]);
        $channels=array_map(static fn($r)=>['id'=>(int)$r['id'],'name'=>$r['name']],$ch->fetchAll());
        $voice=[];
        if(feature_enabled('livekit') && circle_official_voice_allowed($id,$uid) && has_community_permission($id,$uid,'CONNECT_VOICE')){
            $vq=db()->prepare('SELECT id,name,is_locked FROM community_voice_channels WHERE community_id=? AND (expires_at IS NULL OR expires_at>NOW()) AND is_deleting=0 ORDER BY id LIMIT 100');
            $vq->execute([$id]);$voice=array_map(static fn($r)=>['id'=>(int)$r['id'],'name'=>$r['name'],'locked'=>(bool)$r['is_locked']],$vq->fetchAll());
        }
        mobile_reply(['ok'=>true,'community'=>['id'=>(int)$row['id'],'name'=>$row['name'],'description'=>$row['description'],'role'=>$row['member_role'],'icon_url'=>!empty($row['icon_path'])?'/api/mobile.php?route=community-icon&id='.$id:null,'banner_url'=>!empty($row['banner_path'])?'/api/mobile.php?route=community-banner&id='.$id:null,'accent_color'=>$row['accent_color'],'banner_zoom'=>(int)$row['banner_zoom'],'banner_pos_x'=>(int)$row['banner_pos_x'],'banner_pos_y'=>(int)$row['banner_pos_y'],'news_enabled'=>(bool)$row['news_enabled'],'can_post_news'=>(bool)$row['news_enabled']&&circle_can_post_group_news($id,$uid),'channels'=>$channels,'voice_channels'=>$voice]]);
    }
    if($route==='community-manage'){
        mobile_method('POST');$data=mobile_json();$cid=(int)($data['community_id']??0);
        $q=db()->prepare('SELECT owner_id FROM communities WHERE id=?');$q->execute([$cid]);$owner=(int)$q->fetchColumn();
        if($cid<1||circle_is_official($cid)||($owner!==$uid&&!has_community_permission($cid,$uid,'MANAGE_COMMUNITY')))mobile_fail('FORBIDDEN',403);
        $name=trim((string)($data['name']??''));$description=trim((string)($data['description']??''));
        if(mb_strlen($name)<2||mb_strlen($name)>80||mb_strlen($description)>500)mobile_fail('INVALID_COMMUNITY',422);
        db()->prepare('UPDATE communities SET name=?,description=? WHERE id=?')->execute([$name,$description,$cid]);
        audit_event($uid,'community.mobile_updated',['community_id'=>$cid]);mobile_reply(['ok'=>true]);
    }
    if($route==='channel-messages'){
        mobile_method('GET');$channelId=max(0,(int)($_GET['channel_id']??0));$before=max(0,(int)($_GET['before']??0));
        mobile_channel_access($channelId,$uid);
        $q=db()->prepare('SELECT m.id,m.body,m.reply_to_id,m.created_at,u.id AS author_id,u.username,p.display_name FROM messages m JOIN users u ON u.id=m.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE m.channel_id=? AND (?=0 OR m.id<?) ORDER BY m.id DESC LIMIT 40');
        $q->execute([$channelId,$before,$before]);$rows=$q->fetchAll();$items=[];
        foreach($rows as $r)$items[]=['id'=>(int)$r['id'],'body'=>$r['body'],'reply_to_id'=>$r['reply_to_id']===null?null:(int)$r['reply_to_id'],'created_at'=>$r['created_at'],'author'=>mobile_profile(['id'=>$r['author_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>null])];
        if($items){
            $ids=array_column($items,'id');$marks=implode(',',array_fill(0,count($ids),'?'));
            $react=db()->prepare('SELECT message_id,emoji,COUNT(*) AS total,MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM channel_message_reactions WHERE message_id IN ('.$marks.') GROUP BY message_id,emoji');
            $react->execute(array_merge([$uid],$ids));$byMessage=[];
            foreach($react->fetchAll() as $r)$byMessage[(int)$r['message_id']][]=['emoji'=>$r['emoji'],'total'=>(int)$r['total'],'mine'=>(bool)$r['mine']];
            foreach($items as &$item)$item['reactions']=$byMessage[$item['id']]??[];unset($item);
        }
        mobile_reply(['ok'=>true,'items'=>$items,'next_before'=>count($items)===40?$items[count($items)-1]['id']:null]);
    }
    if($route==='channel-send'){
        mobile_method('POST');$d=mobile_json();$channelId=(int)($d['channel_id']??0);$body=trim((string)($d['body']??''));$reply=max(0,(int)($d['reply_to_id']??0));
        if($body===''||mb_strlen($body)>4000)mobile_fail('INVALID_MESSAGE',422);
        $ch=mobile_channel_access($channelId,$uid,true);
        $cfg=db()->prepare('SELECT * FROM community_automod WHERE community_id=?');$cfg->execute([(int)$ch['community_id']]);
        $automod=$cfg->fetch()?:['enabled'=>1,'block_invites'=>1,'block_external_links'=>0,'slowmode_seconds'=>0,'max_repeated_messages'=>3];
        $slow=max((int)$automod['slowmode_seconds'],(int)$ch['slowmode_seconds']);
        $latest=db()->prepare('SELECT body,TIMESTAMPDIFF(SECOND,created_at,NOW()) AS age_seconds FROM messages WHERE channel_id=? AND user_id=? ORDER BY id DESC LIMIT 1');
        $latest->execute([$channelId,$uid]);$last=$latest->fetch();
        if($last&&$slow>0&&(int)$last['age_seconds']<$slow)mobile_fail('SLOWMODE',429);
        if(!empty($automod['enabled'])){
            if(!empty($automod['block_invites'])&&preg_match('~(?:discord\.gg/|discord(?:app)?\.com/invite/)~i',$body))mobile_fail('AUTOMOD_INVITE',422);
            if(!empty($automod['block_external_links'])&&preg_match('~https?://~i',$body))mobile_fail('AUTOMOD_LINK',422);
            if(automod_repeat_blocked($channelId,$uid,$body,(int)($automod['max_repeated_messages']??3)))mobile_fail('AUTOMOD_REPEAT',422);
        }
        if($reply>0){
            $check=db()->prepare('SELECT 1 FROM messages WHERE id=? AND channel_id=?');$check->execute([$reply,$channelId]);
            if(!$check->fetchColumn())mobile_fail('INVALID_REPLY',422);
        }
        if($blocked=circle_trust_preflight_error($body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
        db()->prepare('INSERT INTO messages(channel_id,user_id,body,reply_to_id,created_at) VALUES(?,?,?,?,NOW())')->execute([$channelId,$uid,$body,$reply?:null]);
        mobile_reply(['ok'=>true,'id'=>(int)db()->lastInsertId()]);
    }
    if($route==='channel-react'){
        mobile_method('POST');$d=mobile_json();$id=(int)($d['message_id']??0);$emoji=(string)($d['emoji']??'');
        $allowed=['❤️','👍','😂','🔥','😮','😢','👏','🎉'];if($id<1||!in_array($emoji,$allowed,true))mobile_fail('INVALID_REACTION',422);
        $q=db()->prepare('SELECT channel_id FROM messages WHERE id=?');$q->execute([$id]);$channelId=(int)$q->fetchColumn();
        if(!$channelId)mobile_fail('NOT_FOUND',404);
        mobile_channel_access($channelId,$uid);
        $check=db()->prepare('SELECT 1 FROM channel_message_reactions WHERE message_id=? AND user_id=? AND emoji=?');$check->execute([$id,$uid,$emoji]);
        if($check->fetchColumn())db()->prepare('DELETE FROM channel_message_reactions WHERE message_id=? AND user_id=? AND emoji=?')->execute([$id,$uid,$emoji]);
        else db()->prepare('INSERT IGNORE INTO channel_message_reactions(message_id,user_id,emoji,created_at) VALUES(?,?,?,NOW())')->execute([$id,$uid,$emoji]);
        $q=db()->prepare('SELECT emoji,COUNT(*) AS total,MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM channel_message_reactions WHERE message_id=? GROUP BY emoji');$q->execute([$uid,$id]);
        mobile_reply(['ok'=>true,'reactions'=>array_map(static fn($r)=>['emoji'=>$r['emoji'],'total'=>(int)$r['total'],'mine'=>(bool)$r['mine']],$q->fetchAll())]);
    }
    // Private calls share the web client's dm_call notification and room generation.
    if(in_array($route,['mobile-call-start','mobile-call-poll','mobile-call-decline','mobile-call-accept','mobile-call-unanswered','mobile-call-cancel','mobile-call-token','mobile-call-state','mobile-call-finish','mobile-call-history'],true)){
        if(!feature_enabled('livekit')||!feature_enabled('direct-messages'))mobile_fail('FEATURE_DISABLED',403);
        mobile_call_expire();
        if($route==='mobile-call-history'){
            mobile_method('GET');mobile_reply(['ok'=>true,'items'=>mobile_call_history($uid)]);
        }
        if($route==='mobile-call-poll'){
            mobile_method('GET');
            $q=db()->prepare("SELECT c.id,c.conversation_id,c.caller_id,u.username,p.display_name,p.avatar_path FROM mobile_private_calls c JOIN users u ON u.id=c.caller_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE c.callee_id=? AND c.status='ringing' ORDER BY c.id DESC LIMIT 1");
            $q->execute([$uid]);$r=$q->fetch();
            if($r){
                mobile_dm_access((int)$r['conversation_id'],$uid);
                mobile_reply(['ok'=>true,'call'=>['call_id'=>(int)$r['id'],'id'=>-(int)$r['id'],'conversation_id'=>(int)$r['conversation_id'],'actor_id'=>(int)$r['caller_id'],
                    'peer'=>mobile_profile(['id'=>$r['caller_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])]]);
            }
            $q=db()->prepare("SELECT n.id,n.actor_id,n.payload,u.username,p.display_name,p.avatar_path FROM notifications n JOIN users u ON u.id=n.actor_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE n.user_id=? AND n.kind='dm_call' AND n.read_at IS NULL AND n.created_at>=DATE_SUB(NOW(),INTERVAL 70 SECOND) ORDER BY n.id DESC LIMIT 10");
            $q->execute([$uid]);$incoming=null;
            foreach($q->fetchAll() as $r){
                $payload=json_decode((string)$r['payload'],true)?:[];$cid=(int)($payload['conversation_id']??0);
                if($cid<1||!empty($payload['mobile_call_id'])||!empty($payload['circle_call_id']))continue;
                $count=db()->prepare('SELECT COUNT(*) FROM dm_members WHERE conversation_id=?');$count->execute([$cid]);
                $mine=db()->prepare('SELECT 1 FROM dm_members WHERE conversation_id=? AND user_id=?');$mine->execute([$cid,$uid]);
                if((int)$count->fetchColumn()!==2||!$mine->fetchColumn())continue;
                $incoming=['id'=>(int)$r['id'],'conversation_id'=>$cid,'actor_id'=>(int)$r['actor_id'],
                    'peer'=>mobile_profile(['id'=>$r['actor_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])];break;
            }
            mobile_reply(['ok'=>true,'call'=>$incoming]);
        }
        if($route==='mobile-call-unanswered'){
            mobile_method('GET');
            $items=array_values(array_filter(mobile_call_history($uid),static fn(array $item): bool=>$item['direction']==='incoming'&&$item['status']==='missed'));
            mobile_reply(['ok'=>true,'items'=>array_slice($items,0,30)]);
        }
        if($route==='mobile-call-state'){
            mobile_method('GET');$cid=(int)($_GET['conversation_id']??0);mobile_dm_access($cid,$uid);
            $callId=(int)($_GET['call_id']??0);
            if($callId>0){$call=mobile_call_record($callId,$uid);if((int)$call['conversation_id']!==$cid)mobile_fail('INVALID_CALL',403);
                if(!in_array($call['status'],['ringing','accepted'],true))mobile_reply(['ok'=>true,'state'=>['active'=>false,'call_status'=>$call['status']]]);
                mobile_reply(['ok'=>true,'state'=>['active'=>true,'call_status'=>$call['status']]]);
            }
            mobile_reply(['ok'=>true,'state'=>circle_call_session_status('dm',$cid)]);
        }
        mobile_method('POST');$d=mobile_json();
        if($route==='mobile-call-accept'){
            $callId=(int)($d['call_id']??0);
            if($callId>0){
                $call=mobile_call_record($callId,$uid);
                if((int)$call['callee_id']!==$uid||(int)$call['conversation_id']!==(int)($d['conversation_id']??0))mobile_fail('INVALID_CALL',403);
                $q=db()->prepare("UPDATE mobile_private_calls SET status='accepted',answered_at=NOW(),updated_at=NOW() WHERE id=? AND callee_id=? AND status='ringing' AND created_at>=DATE_SUB(NOW(),INTERVAL 70 SECOND)");
                $q->execute([$callId,$uid]);if($q->rowCount()!==1)mobile_fail('CALL_EXPIRED',409);
                mobile_reply(['ok'=>true,'call_id'=>$callId]);
            }
            $id=(int)($d['notification_id']??0);
            $cid=(int)($d['conversation_id']??0);
            if($id<1||$cid<1)mobile_fail('INVALID_CALL',422);
            mobile_dm_access($cid,$uid);
            // Accept only a recent, pending invitation for the same conversation.
            $q=db()->prepare("SELECT actor_id,payload FROM notifications WHERE id=? AND user_id=? AND kind='dm_call' AND read_at IS NULL AND created_at>=DATE_SUB(NOW(),INTERVAL 70 SECOND) LIMIT 1");
            $q->execute([$id,$uid]);$inv=$q->fetch();
            if(!$inv)mobile_fail('CALL_EXPIRED',409);
            $payload=json_decode((string)$inv['payload'],true)?:[];
            if((int)($payload['conversation_id']??0)!==$cid||(int)$inv['actor_id']===$uid)mobile_fail('INVALID_CALL',403);
            $q=db()->prepare('SELECT 1 FROM dm_members WHERE conversation_id=? AND user_id=?');$q->execute([$cid,(int)$inv['actor_id']]);
            if(!$q->fetchColumn())mobile_fail('CALL_EXPIRED',409);
            // Acknowledge but never terminate the room on acceptance.
            db()->prepare("UPDATE notifications SET read_at=NOW() WHERE id=? AND user_id=? AND kind='dm_call' AND read_at IS NULL")->execute([$id,$uid]);
            mobile_reply(['ok'=>true]);
        }
        if($route==='mobile-call-decline'){
            $callId=(int)($d['call_id']??0);
            if($callId>0){$call=mobile_call_record($callId,$uid);
                if((int)$call['callee_id']!==$uid)mobile_fail('FORBIDDEN',403);
                db()->prepare("UPDATE mobile_private_calls SET status='declined',ended_at=NOW(),updated_at=NOW() WHERE id=? AND callee_id=? AND status='ringing'")->execute([$callId,$uid]);
                mobile_reply(['ok'=>true]);
            }
            $id=(int)($d['notification_id']??0);
            if($id<1)mobile_fail('INVALID_CALL',422);
            $q=db()->prepare("UPDATE notifications SET read_at=NOW() WHERE id=? AND user_id=? AND kind='dm_call' AND read_at IS NULL");
            $q->execute([$id,$uid]);mobile_reply(['ok'=>true]);
        }
        $cid=(int)($d['conversation_id']??0);mobile_dm_access($cid,$uid);
        if($route==='mobile-call-start'){
            $q=db()->prepare('SELECT user_id FROM dm_members WHERE conversation_id=? AND user_id<>? LIMIT 1');$q->execute([$cid,$uid]);$peer=(int)$q->fetchColumn();
            if($peer<1)mobile_fail('FORBIDDEN',403);
            $existing=db()->prepare("SELECT id FROM mobile_private_calls WHERE conversation_id=? AND caller_id=? AND status IN ('ringing','accepted') ORDER BY id DESC LIMIT 1");
            $existing->execute([$cid,$uid]);$oldId=(int)$existing->fetchColumn();
            if($oldId)mobile_reply(['ok'=>true,'call_id'=>$oldId,'reused'=>true]);
            $recent=db()->prepare("SELECT COUNT(*) FROM mobile_private_calls WHERE caller_id=? AND created_at>=DATE_SUB(NOW(),INTERVAL 60 SECOND)");
            $recent->execute([$uid]);if((int)$recent->fetchColumn()>=3)mobile_fail('CALL_RATE_LIMIT',429);
            // A conversation-level advisory lock serialises concurrent requests on shared hosting.
            $lockKey='circle_mcall_'.$cid;
            $lock=db()->prepare('SELECT GET_LOCK(?,3)');$lock->execute([$lockKey]);if((int)$lock->fetchColumn()!==1)mobile_fail('CALL_BUSY',409);
            try{
                $existing->execute([$cid,$uid]);$oldId=(int)$existing->fetchColumn();
                if($oldId)mobile_reply(['ok'=>true,'call_id'=>$oldId,'reused'=>true]);
                $opposite=db()->prepare("SELECT id FROM mobile_private_calls WHERE conversation_id=? AND status IN ('ringing','accepted') ORDER BY id DESC LIMIT 1");
                $opposite->execute([$cid]);if($opposite->fetchColumn())mobile_fail('CALL_BUSY',409);
                db()->prepare("INSERT INTO mobile_private_calls(conversation_id,caller_id,callee_id,status,created_at,updated_at) VALUES(?,?,?,'ringing',NOW(),NOW())")->execute([$cid,$uid,$peer]);
                $newId=(int)db()->lastInsertId();
                try{notify_user($peer,'dm_call',$uid,['conversation_id'=>$cid,'mobile_call_id'=>$newId]);}
                catch(Throwable $e){db()->prepare("UPDATE mobile_private_calls SET status='cancelled',ended_at=NOW(),updated_at=NOW() WHERE id=?")->execute([$newId]);throw $e;}
                mobile_reply(['ok'=>true,'call_id'=>$newId]);
            }finally{db()->prepare('SELECT RELEASE_LOCK(?)')->execute([$lockKey]);}
        }
        if($route==='mobile-call-cancel'){
            $callId=(int)($d['call_id']??0);
            if($callId>0){$call=mobile_call_record($callId,$uid);
                if((int)$call['caller_id']!==$uid||$cid!==(int)$call['conversation_id'])mobile_fail('FORBIDDEN',403);
                db()->prepare("UPDATE mobile_private_calls SET status=IF(status='ringing','cancelled','ended'),ended_at=NOW(),updated_at=NOW() WHERE id=? AND caller_id=? AND status IN ('ringing','accepted')")->execute([$callId,$uid]);
                mobile_reply(['ok'=>true]);
            }
            $q=db()->prepare('SELECT user_id FROM dm_members WHERE conversation_id=? AND user_id<>? LIMIT 1');$q->execute([$cid,$uid]);$peer=(int)$q->fetchColumn();
            $q=db()->prepare("SELECT id,payload FROM notifications WHERE user_id=? AND actor_id=? AND kind='dm_call' AND read_at IS NULL");$q->execute([$peer,$uid]);
            foreach($q->fetchAll() as $row){$pay=json_decode((string)$row['payload'],true)?:[];
                if((int)($pay['conversation_id']??0)===$cid)db()->prepare('UPDATE notifications SET read_at=NOW() WHERE id=?')->execute([(int)$row['id']]);
            }
            mobile_reply(['ok'=>true]);
        }
        if($route==='mobile-call-finish'){
            $callId=(int)($d['call_id']??0);if($callId<1)mobile_fail('INVALID_CALL',422);
            $call=mobile_call_record($callId,$uid);if((int)$call['conversation_id']!==$cid)mobile_fail('INVALID_CALL',403);
            db()->prepare("UPDATE mobile_private_calls SET status=IF(status='ringing',IF(caller_id=?,'cancelled','declined'),'ended'),ended_at=NOW(),updated_at=NOW() WHERE id=? AND status IN ('ringing','accepted')")->execute([$uid,$callId]);
            mobile_reply(['ok'=>true]);
        }
        if($route==='mobile-call-token'){
            $callId=(int)($d['call_id']??0);
            if($callId>0){$call=mobile_call_record($callId,$uid);
                if((int)$call['conversation_id']!==$cid||!in_array($call['status'],['ringing','accepted'],true))mobile_fail('CALL_UNAVAILABLE',409);
                if((int)$call['callee_id']===$uid&&$call['status']!=='accepted')mobile_fail('CALL_NOT_ACCEPTED',403);
            }
            $url=trim(setting('livekit_url'));$parsed=parse_url($url);
            if(!is_array($parsed)||strtolower((string)($parsed['scheme']??''))!=='wss'||empty($parsed['host'])||isset($parsed['user'])||isset($parsed['pass'])||isset($parsed['fragment']))mobile_fail('LIVEKIT_NOT_CONFIGURED',503);
            $session=circle_call_session('dm',$cid,true);
            if(!$session||$session['status']!=='active')mobile_fail('CALL_UNAVAILABLE',409);
            // Same room lifecycle as the web version. Camera and microphone are opt-in on the client.
            try{$token=livekit_token($actor,(string)$session['room_name'],120);}catch(Throwable){mobile_fail('LIVEKIT_NOT_CONFIGURED',503);}
            mobile_reply(['ok'=>true,'url'=>$url,'token'=>$token,'room'=>$session['room_name'],'expires_in'=>120,'mode'=>'private_call']);
        }
    }
    if($route==='mobile-voice-token'){
        mobile_method('POST');if(!feature_enabled('livekit'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$voiceId=(int)($d['voice_channel_id']??0);if($voiceId<1)mobile_fail('INVALID_CHANNEL',400);
        $q=db()->prepare('SELECT v.room_key,v.community_id,v.is_locked,v.is_deleting FROM community_voice_channels v JOIN community_members cm ON cm.community_id=v.community_id AND cm.user_id=? JOIN communities c ON c.id=v.community_id AND c.voice_enabled=1 WHERE v.id=? AND (v.expires_at IS NULL OR v.expires_at>NOW()) LIMIT 1');
        $q->execute([$uid,$voiceId]);$v=$q->fetch();if(!$v)mobile_fail('FORBIDDEN',403);
        $cid=(int)$v['community_id'];
        $ban=db()->prepare('SELECT 1 FROM community_voice_bans WHERE community_id=? AND user_id=? AND expires_at>NOW() LIMIT 1');$ban->execute([$cid,$uid]);
        if($ban->fetchColumn()||!circle_official_voice_allowed($cid,$uid)||(int)$v['is_deleting']||((int)$v['is_locked']&&!has_community_permission($cid,$uid,'MANAGE_CHANNELS'))||(!has_community_permission($cid,$uid,'CONNECT_VOICE')&&!has_community_permission($cid,$uid,'CREATE_TEMP_VOICE')))mobile_fail('FORBIDDEN',403);
        // Mobile LiveKit credentials are short lived and must use encrypted signaling.
        $livekitUrl=trim(setting('livekit_url'));
        $parsed=parse_url($livekitUrl);
        if(!is_array($parsed) || strtolower((string)($parsed['scheme']??''))!=='wss' || empty($parsed['host']) || isset($parsed['user']) || isset($parsed['pass']) || isset($parsed['fragment']))mobile_fail('LIVEKIT_NOT_CONFIGURED',503);
        try{$token=mobile_voice_token($u,'circle-vc-'.$v['room_key']);}catch(Throwable){mobile_fail('LIVEKIT_NOT_CONFIGURED',503);}
        mobile_reply(['ok'=>true,'url'=>$livekitUrl,'token'=>$token,'room'=>'circle-vc-'.$v['room_key'],'expires_in'=>120,'mode'=>'audio_only']);
    }
    if($route==='push-register'||$route==='push-unregister'){
        mobile_method('POST');$d=mobile_json();$platform=(string)($d['platform']??'');$raw=trim((string)($d['token']??''));
        if(!in_array($platform,['android','ios'],true)||strlen($raw)<32||strlen($raw)>512||!preg_match('/^[A-Za-z0-9:._~-]+$/D',$raw))mobile_fail('INVALID_PUSH_TOKEN',422);
        $fp=hash_hmac('sha256',$platform.':'.$raw,setting('app_key'));
        if($route==='push-unregister'){
            db()->prepare('DELETE FROM mobile_push_devices WHERE token_fingerprint=? AND user_id=? AND mobile_token_id=?')->execute([$fp,$uid,(int)$u['token_id']]);
        }else{
            // The encrypted token is retained for a future delivery worker; never return it in API output.
            $enc=encrypt_secret($raw);
            db()->prepare('INSERT INTO mobile_push_devices(mobile_token_id,user_id,platform,push_token_enc,token_fingerprint,created_at,updated_at) VALUES(?,?,?,?,?,NOW(),NOW()) ON DUPLICATE KEY UPDATE mobile_token_id=VALUES(mobile_token_id),user_id=VALUES(user_id),push_token_enc=VALUES(push_token_enc),updated_at=NOW()')->execute([(int)$u['token_id'],$uid,$platform,$enc,$fp]);
        }
        mobile_reply(['ok'=>true,'delivery_enabled'=>false]);
    }
    if($route==='invite-preview'||$route==='invite-join'){
        mobile_method($route==='invite-preview'?'GET':'POST');if(!feature_enabled('community-invites'))mobile_fail('FEATURE_DISABLED',403);
        $input=$route==='invite-join'?mobile_json():$_GET;
        $token=trim((string)($input['token']??''));if(!preg_match('/^[a-f0-9]{48}$/D',$token))mobile_fail('INVALID_INVITE',400);
        $hash=hash_hmac('sha256',$token,setting('app_key'));
        $q=db()->prepare('SELECT i.id,i.community_id,c.name,c.description,i.uses,i.max_uses FROM community_invites i JOIN communities c ON c.id=i.community_id WHERE i.token_hash=? AND i.revoked_at IS NULL AND (i.expires_at IS NULL OR i.expires_at>NOW()) AND (i.max_uses IS NULL OR i.uses<i.max_uses) LIMIT 1');
        $q->execute([$hash]);$invite=$q->fetch();if(!$invite)mobile_fail('INVITE_EXPIRED',410);
        $cid=(int)$invite['community_id'];
        $ban=db()->prepare('SELECT 1 FROM community_bans WHERE community_id=? AND user_id=? AND (expires_at IS NULL OR expires_at>NOW())');$ban->execute([$cid,$uid]);if($ban->fetchColumn())mobile_fail('COMMUNITY_BANNED',403);
        $already=db()->prepare('SELECT 1 FROM community_members WHERE community_id=? AND user_id=?');$already->execute([$cid,$uid]);$member=(bool)$already->fetchColumn();
        if($route==='invite-preview')mobile_reply(['ok'=>true,'community'=>['id'=>$cid,'name'=>$invite['name'],'description'=>$invite['description']],'already_member'=>$member]);
        if(!$member){
            db()->beginTransaction();
            try {
                $claim=db()->prepare('UPDATE community_invites SET uses=uses+1 WHERE id=? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>NOW()) AND (max_uses IS NULL OR uses<max_uses)');$claim->execute([(int)$invite['id']]);
                if($claim->rowCount()!==1){db()->rollBack();mobile_fail('INVITE_EXPIRED',410);}
                $insert=db()->prepare("INSERT IGNORE INTO community_members(community_id,user_id,member_role,joined_at) VALUES(?,?,'MEMBER',NOW())");
                $insert->execute([$cid,$uid]);
                // A concurrent join for this same user must not consume a second invite use.
                if($insert->rowCount()===0)db()->prepare('UPDATE community_invites SET uses=uses-1 WHERE id=? AND uses>0')->execute([(int)$invite['id']]);
                db()->commit();
            }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        }
        mobile_reply(['ok'=>true,'community_id'=>$cid,'already_member'=>$member]);
    }
    if($route==='notifications'){
        mobile_method('GET');if(!feature_enabled('notifications'))mobile_fail('FEATURE_DISABLED',403);
        $before=max(0,(int)($_GET['before']??0));
        $q=db()->prepare('SELECT n.id,n.kind,n.payload,n.created_at,n.read_at,u.username,p.display_name FROM notifications n LEFT JOIN users u ON u.id=n.actor_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE n.user_id=? AND (?=0 OR n.id<?) ORDER BY n.id DESC LIMIT 40');
        $q->execute([$uid,$before,$before]);$items=[];
        foreach($q->fetchAll() as $n)$items[]=['id'=>(int)$n['id'],'kind'=>$n['kind'],'payload'=>json_decode((string)($n['payload']??''),true)?:new stdClass(),'created_at'=>$n['created_at'],'read'=>$n['read_at']!==null,'actor_name'=>$n['display_name']?:$n['username']];
        $unread=db()->prepare('SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL');$unread->execute([$uid]);
        mobile_reply(['ok'=>true,'items'=>$items,'unread'=>(int)$unread->fetchColumn(),'next_before'=>count($items)===40?$items[count($items)-1]['id']:null]);
    }
    if($route==='notification-read'){
        mobile_method('POST');$data=mobile_json();$id=max(0,(int)($data['id']??0));
        if($id===0)db()->prepare('UPDATE notifications SET read_at=NOW() WHERE user_id=? AND read_at IS NULL')->execute([$uid]);
        else db()->prepare('UPDATE notifications SET read_at=NOW() WHERE id=? AND user_id=? AND read_at IS NULL')->execute([$id,$uid]);
        mobile_reply(['ok'=>true]);
    }
    if($route==='notification-settings'){
        if(!feature_enabled('notifications'))mobile_fail('FEATURE_DISABLED',403);
        $allowed=['messages','friends','communities','security_alerts','system','push_enabled'];
        if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
            $data=mobile_json();if(!$data||count(array_diff(array_keys($data),$allowed))>0)mobile_fail('INVALID_SETTINGS',422);
            foreach($data as $v)if(!is_bool($v))mobile_fail('INVALID_SETTINGS',422);
            // Preference gates browser and mobile push; actual native delivery requires FCM credentials, device registration and cron.
            db()->prepare('INSERT INTO notification_preferences(user_id,updated_at) VALUES(?,NOW()) ON DUPLICATE KEY UPDATE updated_at=NOW()')->execute([$uid]);
            $pairs=[];$values=[];foreach($data as $k=>$v){$pairs[]=$k.'=?';$values[]=$v?1:0;}
            $values[]=$uid;db()->prepare('UPDATE notification_preferences SET '.implode(',',$pairs).',updated_at=NOW() WHERE user_id=?')->execute($values);
        }else mobile_method('GET');
        $q=db()->prepare('SELECT messages,friends,communities,security_alerts,system,push_enabled FROM notification_preferences WHERE user_id=?');$q->execute([$uid]);$p=$q->fetch()?:[];
        $settings=[];foreach($allowed as $key)$settings[$key]=array_key_exists($key,$p)?(bool)$p[$key]:($key!=='push_enabled');
        mobile_reply(['ok'=>true,'settings'=>$settings,'push_available'=>false]);
    }
    if($route==='cinema-rooms'){
        mobile_method('GET');$q=db()->prepare("SELECT r.id,r.title,r.provider,r.created_at,r.owner_id FROM cinema_rooms r JOIN cinema_members m ON m.room_id=r.id AND m.user_id=? WHERE r.status='OPEN' ORDER BY r.id DESC LIMIT 40");
        $q->execute([$uid]);mobile_reply(['ok'=>true,'items'=>$q->fetchAll()]);
    }
    if($route==='admin-summary'){
        mobile_method('GET');if(!in_array((string)($actor['platform_role']??''),['OWNER','ADMIN'],true))mobile_fail('FORBIDDEN',403);
        $pending=(int)db()->query("SELECT COUNT(*) FROM circle_trust_cases WHERE status IN ('OPEN','REVIEWING')")->fetchColumn();
        $users=(int)db()->query('SELECT COUNT(*) FROM users')->fetchColumn();
        $q=db()->query("SELECT c.id,c.target_user_id,c.source_type,c.excerpt,c.created_at,u.username FROM circle_trust_cases c JOIN users u ON u.id=c.target_user_id WHERE c.status IN ('OPEN','REVIEWING') ORDER BY c.id DESC LIMIT 30");
        mobile_reply(['ok'=>true,'users'=>$users,'pending'=>$pending,'cases'=>$q->fetchAll()]);
    }
    if($route==='friends'){
        mobile_method('GET');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $q=db()->prepare("SELECT u.id,u.username,p.display_name,p.avatar_path FROM friendships f JOIN users u ON u.id=IF(f.requester_id=?,f.addressee_id,f.requester_id) LEFT JOIN user_profiles p ON p.user_id=u.id WHERE f.status='ACCEPTED' AND (f.requester_id=? OR f.addressee_id=?) ORDER BY COALESCE(p.display_name,u.username) LIMIT 300");
        $q->execute([$uid,$uid,$uid]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);$verified=mobile_verified_map($rows);
        foreach($rows as &$row)$row['verified']=!empty($verified[(int)$row['id']]);unset($row);
        mobile_reply(['ok'=>true,'items'=>array_map('mobile_profile',$rows)]);
    }
    if($route==='friend-requests'){
        mobile_method('GET');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $q=db()->prepare("SELECT f.id AS friendship_id,f.requester_id,f.addressee_id,u.id,u.username,p.display_name,p.avatar_path,f.created_at FROM friendships f JOIN users u ON u.id=IF(f.requester_id=?,f.addressee_id,f.requester_id) LEFT JOIN user_profiles p ON p.user_id=u.id WHERE f.status='PENDING' AND (f.requester_id=? OR f.addressee_id=?) ORDER BY f.updated_at DESC LIMIT 100");
        $q->execute([$uid,$uid,$uid]);$list=[];
        foreach($q->fetchAll(PDO::FETCH_ASSOC) as $row){$list[]=['friendship_id'=>(int)$row['friendship_id'],'direction'=>(int)$row['addressee_id']===$uid?'incoming':'outgoing','created_at'=>$row['created_at'],'person'=>mobile_profile($row)];}
        mobile_reply(['ok'=>true,'items'=>$list]);
    }
    if($route==='people-search'){
        mobile_method('GET');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $term=trim((string)($_GET['q']??''));if(mb_strlen($term)<2||mb_strlen($term)>40)mobile_fail('INVALID_SEARCH',422);
        $safe=str_replace(['!','%','_'],['!!','!%','!_'],$term);
        $q=db()->prepare("SELECT u.id,u.username,p.display_name,p.avatar_path FROM users u LEFT JOIN user_profiles p ON p.user_id=u.id WHERE u.id<>? AND (u.username LIKE ? ESCAPE '!' OR p.display_name LIKE ? ESCAPE '!') AND NOT EXISTS(SELECT 1 FROM friendships f WHERE f.status='BLOCKED' AND ((f.requester_id=? AND f.addressee_id=u.id) OR (f.addressee_id=? AND f.requester_id=u.id))) ORDER BY u.username LIMIT 30");
        $q->execute([$uid,'%'.$safe.'%','%'.$safe.'%',$uid,$uid]);$rows=$q->fetchAll(PDO::FETCH_ASSOC);$verified=mobile_verified_map($rows);
        foreach($rows as &$row)$row['verified']=!empty($verified[(int)$row['id']]);unset($row);
        mobile_reply(['ok'=>true,'items'=>array_map('mobile_profile',$rows)]);
    }
    if($route==='friend-request'){
        mobile_method('POST');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$target=(int)($data['user_id']??0);
        if($target<1||$target===$uid)mobile_fail('INVALID_USER',422);
        $targetQ=db()->prepare('SELECT id FROM users WHERE id=?');$targetQ->execute([$target]);if(!$targetQ->fetchColumn())mobile_fail('NOT_FOUND',404);
        $q=db()->prepare('SELECT id,status FROM friendships WHERE (requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?) LIMIT 1');
        $q->execute([$uid,$target,$target,$uid]);$existing=$q->fetch(PDO::FETCH_ASSOC);
        if($existing&&$existing['status']==='BLOCKED')mobile_fail('FORBIDDEN',403);
        if($existing&&in_array($existing['status'],['ACCEPTED','PENDING'],true))mobile_fail('ALREADY_EXISTS',409);
        if($existing){db()->prepare("UPDATE friendships SET requester_id=?,addressee_id=?,status='PENDING',updated_at=NOW() WHERE id=?")->execute([$uid,$target,$existing['id']]);}
        else{db()->prepare("INSERT INTO friendships(requester_id,addressee_id,status,created_at,updated_at) VALUES(?,?,'PENDING',NOW(),NOW())")->execute([$uid,$target]);}
        try{notify_user($target,'friend_request',$uid);}catch(Throwable $error){error_log('Circle Mobile friend notification: '.$error->getMessage());}
        mobile_reply(['ok'=>true]);
    }
    if($route==='friend-respond'){
        mobile_method('POST');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$id=(int)($data['friendship_id']??0);$decision=(string)($data['decision']??'');
        if($id<1||!in_array($decision,['ACCEPTED','DECLINED'],true))mobile_fail('INVALID_FRIEND_RESPONSE',422);
        $q=db()->prepare("SELECT requester_id FROM friendships WHERE id=? AND addressee_id=? AND status='PENDING'");
        $q->execute([$id,$uid]);$requester=(int)$q->fetchColumn();if(!$requester)mobile_fail('NOT_FOUND',404);
        $q=db()->prepare("UPDATE friendships SET status=?,updated_at=NOW() WHERE id=? AND addressee_id=? AND status='PENDING'");
        $q->execute([$decision,$id,$uid]);if(!$q->rowCount())mobile_fail('NOT_FOUND',404);
        if($decision==='ACCEPTED'){try{notify_user($requester,'friend_accepted',$uid);}catch(Throwable $error){error_log('Circle Mobile friend notification: '.$error->getMessage());}}
        mobile_reply(['ok'=>true]);
    }
    if($route==='friend-remove' || $route==='friend-request-cancel'){
        mobile_method('POST');if(!feature_enabled('friends'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$target=(int)($data['user_id']??0);$id=(int)($data['friendship_id']??0);
        if($route==='friend-remove'){
            if($target<1||$target===$uid)mobile_fail('INVALID_USER',422);
            $q=db()->prepare("DELETE FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?))");
            $q->execute([$uid,$target,$target,$uid]);
        }else{
            if($id<1)mobile_fail('INVALID_FRIEND_RESPONSE',422);
            $q=db()->prepare("DELETE FROM friendships WHERE id=? AND requester_id=? AND status='PENDING'");$q->execute([$id,$uid]);
        }
        if(!$q->rowCount())mobile_fail('NOT_FOUND',404);
        mobile_reply(['ok'=>true]);
    }
    // Per-community feed: membership and active-ban checks are mandatory, never leak private posts.
    if($route==='community-feed'){
        mobile_method('GET');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $cid=(int)($_GET['id']??0);$before=max(0,(int)($_GET['before']??0));
        if($cid<1)mobile_fail('INVALID_COMMUNITY',422);
        $access=db()->prepare('SELECT 1 FROM community_members WHERE community_id=? AND user_id=? LIMIT 1');
        $access->execute([$cid,$uid]);if(!$access->fetchColumn())mobile_fail('FORBIDDEN',403);
        $ban=db()->prepare('SELECT 1 FROM community_bans WHERE community_id=? AND user_id=? AND (expires_at IS NULL OR expires_at>NOW()) LIMIT 1');
        $ban->execute([$cid,$uid]);if($ban->fetchColumn())mobile_fail('COMMUNITY_BANNED',403);
        $q=db()->prepare("SELECT p.id,p.title,p.body,p.created_at,p.media_path,p.media_mime,p.comments_enabled,p.is_pinned,p.community_id,u.id AS author_id,u.username,pr.display_name,pr.avatar_path,IF(v.user_id IS NOT NULL,1,0) AS verified,c.name AS community_name,IF(vc.community_id IS NOT NULL,1,0) AS community_verified,c.icon_path AS community_icon FROM social_posts p JOIN users u ON u.id=p.author_id LEFT JOIN user_profiles pr ON pr.user_id=u.id LEFT JOIN circle_verified_profiles v ON v.user_id=u.id LEFT JOIN communities c ON c.id=p.community_id LEFT JOIN circle_verified_communities vc ON vc.community_id=p.community_id WHERE p.scope_type='GROUP' AND p.community_id=? AND (?=0 OR p.id<?) ORDER BY p.id DESC LIMIT 20");
        $q->execute([$cid,$before,$before]);$rows=$q->fetchAll();$items=[];
        $stats=mobile_post_stats_bulk(array_column($rows,'id'),$uid);
        foreach($rows as $r){$id=(int)$r['id'];$items[]=['id'=>$id,'title'=>(string)$r['title'],'body'=>(string)$r['body'],'created_at'=>$r['created_at'],'has_media'=>!empty($r['media_path']),'media_mime'=>$r['media_mime'],'comments_enabled'=>(bool)$r['comments_enabled'],'can_edit'=>(int)$r['author_id']===$uid,'is_pinned'=>!empty($r['is_pinned']),'stats'=>$stats[$id],'author'=>mobile_profile(['id'=>$r['author_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path'],'verified'=>$r['verified']]),'community'=>['id'=>(int)$r['community_id'],'name'=>$r['community_name'],'verified'=>(bool)$r['community_verified'],'icon_url'=>!empty($r['community_icon'])?'/api/mobile.php?route=community-icon&id='.$r['community_id']:null]];}
        mobile_reply(['ok'=>true,'items'=>$items,'next_before'=>count($rows)===20?(int)$rows[count($rows)-1]['id']:null]);
    }
    if($route==='feed'){
        mobile_method('GET');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $before=max(0,(int)($_GET['before']??0));
        $q=db()->prepare("SELECT p.id,p.title,p.body,p.created_at,p.scope_type,p.media_path,p.media_mime,p.comments_enabled,p.is_pinned,p.community_id,u.id AS author_id,u.username,pr.display_name,pr.avatar_path,IF(v.user_id IS NOT NULL,1,0) AS verified,c.name AS community_name,IF(vc.community_id IS NOT NULL,1,0) AS community_verified,c.icon_path AS community_icon FROM social_posts p JOIN users u ON u.id=p.author_id LEFT JOIN user_profiles pr ON pr.user_id=u.id LEFT JOIN circle_verified_profiles v ON v.user_id=u.id LEFT JOIN communities c ON c.id=p.community_id LEFT JOIN circle_verified_communities vc ON vc.community_id=p.community_id WHERE (?=0 OR p.id<?) AND ((p.scope_type='USER' AND (p.author_id=? OR p.visibility='PUBLIC' OR (p.visibility='FRIENDS' AND EXISTS (SELECT 1 FROM friendships f WHERE f.status='ACCEPTED' AND ((f.requester_id=? AND f.addressee_id=p.author_id) OR (f.addressee_id=? AND f.requester_id=p.author_id)))))) OR (p.scope_type='GROUP' AND EXISTS(SELECT 1 FROM community_members m WHERE m.community_id=p.community_id AND m.user_id=?))) ORDER BY p.created_at DESC,p.id DESC LIMIT 30");
        $q->execute([$before,$before,$uid,$uid,$uid,$uid]);$items=[];
        $rows=$q->fetchAll();$stats=mobile_post_stats_bulk(array_column($rows,'id'),$uid);
        foreach($rows as $r){$id=(int)$r['id'];$items[]=['id'=>$id,'title'=>$r['title'],'body'=>$r['body'],'created_at'=>$r['created_at'],'scope'=>$r['scope_type'],'has_media'=>!empty($r['media_path']),'media_mime'=>$r['media_mime'],'comments_enabled'=>(bool)$r['comments_enabled'],'can_edit'=>(int)$r['author_id']===$uid,'is_pinned'=>!empty($r['is_pinned']),'stats'=>$stats[$id],'author'=>mobile_profile(['id'=>$r['author_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path'],'verified'=>$r['verified']]),'community'=>$r['scope_type']==='GROUP'?['id'=>(int)$r['community_id'],'name'=>$r['community_name'],'verified'=>(bool)$r['community_verified'],'icon_url'=>!empty($r['community_icon'])?'/api/mobile.php?route=community-icon&id='.$r['community_id']:null]:null];}
        mobile_reply(['ok'=>true,'items'=>$items,'next_before'=>count($items)===30?$items[count($items)-1]['id']:null]);
    }
    if($route==='post-media' || $route==='story-media'){
        mobile_method('GET');$id=(int)($_GET['id']??0);if($id<1)mobile_fail('NOT_FOUND',404);
        if($route==='post-media'){$p=mobile_post_access($id,$uid);if(empty($p['media_path']))mobile_fail('NOT_FOUND',404);mobile_social_media((string)$p['media_path'],(string)$p['media_mime']);}
        $q=db()->prepare('SELECT user_id,media_path,media_mime FROM social_stories WHERE id=? AND expires_at>NOW() LIMIT 1');$q->execute([$id]);$s=$q->fetch();if(!$s)mobile_fail('NOT_FOUND',404);
        if((int)$s['user_id']!==$uid){$m=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");$m->execute([$uid,(int)$s['user_id'],(int)$s['user_id'],$uid]);if(!$m->fetchColumn())mobile_fail('FORBIDDEN',403);}
        mobile_social_media((string)$s['media_path'],(string)$s['media_mime']);
    }
    if($route==='stories'){
        mobile_method('GET');if(!feature_enabled('stories'))mobile_fail('FEATURE_DISABLED',403);
        $q=db()->prepare("SELECT s.id,s.user_id,s.caption,s.media_mime,s.created_at,u.username,p.display_name,p.avatar_path FROM social_stories s JOIN users u ON u.id=s.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE s.expires_at>NOW() AND (s.user_id=? OR EXISTS(SELECT 1 FROM friendships f WHERE f.status='ACCEPTED' AND ((f.requester_id=? AND f.addressee_id=s.user_id) OR (f.addressee_id=? AND f.requester_id=s.user_id)))) ORDER BY s.created_at DESC LIMIT 30");
        $q->execute([$uid,$uid,$uid]);$items=[];foreach($q->fetchAll() as $r)$items[]=['id'=>(int)$r['id'],'caption'=>$r['caption'],'media_mime'=>$r['media_mime'],'created_at'=>$r['created_at'],'author'=>mobile_profile(['id'=>$r['user_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])];mobile_reply(['ok'=>true,'items'=>$items]);
    }
    if($route==='community-post-create'){
        mobile_method('POST');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$cid=(int)($d['community_id']??0);
        $title=trim((string)($d['title']??''));$body=trim((string)($d['body']??''));
        if($cid<1||$title===''||mb_strlen($title)>140||mb_strlen($body)>4000)mobile_fail('INVALID_POST',422);
        $q=db()->prepare('SELECT news_enabled FROM communities c JOIN community_members m ON m.community_id=c.id WHERE c.id=? AND m.user_id=? LIMIT 1');
        $q->execute([$cid,$uid]);$enabled=$q->fetchColumn();if($enabled===false)mobile_fail('FORBIDDEN',403);
        if(!(bool)$enabled)mobile_fail('NEWS_DISABLED',403);
        $ban=db()->prepare('SELECT 1 FROM community_bans WHERE community_id=? AND user_id=? AND (expires_at IS NULL OR expires_at>NOW()) LIMIT 1');
        $ban->execute([$cid,$uid]);if($ban->fetchColumn())mobile_fail('COMMUNITY_BANNED',403);
        if(!circle_can_post_group_news($cid,$uid))mobile_fail('FORBIDDEN',403);
        $asCommunity=circle_can_post_as_community($cid,$uid);
        if(!$asCommunity&&!circle_can_post_as_self($cid,$uid))mobile_fail('FORBIDDEN',403);
        if($blocked=circle_trust_preflight_error($title.' '.$body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
        db()->prepare("INSERT INTO social_posts(scope_type,author_id,community_id,title,body,visibility,published_as_community,comments_enabled,created_at) VALUES('GROUP',?,?,?,?,'GROUP',?,1,NOW())")->execute([$uid,$cid,$title,$body,$asCommunity?1:0]);
        mobile_reply(['ok'=>true,'post_id'=>(int)db()->lastInsertId()],201);
    }
    if($route==='post-create' || $route==='post-upload'){
        mobile_method('POST');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $data=$route==='post-upload'?$_POST:mobile_json();
        $title=trim((string)($data['title']??''));$body=trim((string)($data['body']??''));
        if($title===''||mb_strlen($title)>140||mb_strlen($body)>4000)mobile_fail('INVALID_POST',422);
        if($blocked=circle_trust_preflight_error($title.' '.$body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
        $media=null;
        if($route==='post-upload'){
            if(!feature_enabled('social-post-media'))mobile_fail('FEATURE_DISABLED',403);
            $file=$_FILES['media']??[];$size=(int)($file['size']??0);
            if(($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK||$size<1||$size>15*1024*1024||!is_uploaded_file((string)($file['tmp_name']??'')))mobile_fail('INVALID_UPLOAD',422);
            $mime=(new finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']);$types=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp','image/gif'=>'gif','video/mp4'=>'mp4','video/webm'=>'webm'];
            if(!isset($types[$mime])||(str_starts_with($mime,'image/')&&!getimagesize($file['tmp_name'])))mobile_fail('UNSUPPORTED_MEDIA',415);
            $dir=storage_dir().'/circle-media';if(!is_dir($dir)&&!mkdir($dir,0700,true)&&!is_dir($dir))mobile_fail('STORAGE_ERROR',500);
            $name=bin2hex(random_bytes(24)).'.'.$types[$mime];if(!move_uploaded_file($file['tmp_name'],$dir.'/'.$name))mobile_fail('UPLOAD_FAILED',500);
            $media=['name'=>$name,'mime'=>$mime];
        }
        try{db()->prepare("INSERT INTO social_posts(scope_type,author_id,title,body,media_path,media_mime,visibility,comments_enabled,created_at) VALUES('USER',?,?,?,?,?,'FRIENDS',1,NOW())")->execute([$uid,$title,$body,$media['name']??null,$media['mime']??null]);}
        catch(Throwable $error){if($media)@unlink(storage_dir().'/circle-media/'.$media['name']);throw $error;}
        mobile_reply(['ok'=>true,'post_id'=>(int)db()->lastInsertId()],201);
    }
    // Native desktop post management. Every write checks authentication and ownership server-side.
    if($route==='post-edit'){
        mobile_method('POST');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$id=(int)($d['post_id']??0);$field=(string)($d['field']??'');
        if(!in_array($field,['title','body','comments'],true))mobile_fail('INVALID_FIELD',422);
        $post=mobile_post_access($id,$uid);
        if((int)$post['author_id']!==$uid)mobile_fail('FORBIDDEN',403);
        if($field==='comments'){
            $enabled=($d['enabled']??false)===true?1:0;
            db()->prepare('UPDATE social_posts SET comments_enabled=?,updated_at=NOW() WHERE id=? AND author_id=?')->execute([$enabled,$id,$uid]);
        }else{
            $value=trim((string)($d['value']??''));
            if(($field==='title'&&($value===''||mb_strlen($value)>140))||($field==='body'&&mb_strlen($value)>4000))mobile_fail('INVALID_POST',422);
            if($blocked=circle_trust_preflight_error($value))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
            $column=$field==='title'?'title':'body';
            db()->prepare('UPDATE social_posts SET '.$column.'=?,updated_at=NOW() WHERE id=? AND author_id=?')->execute([$value,$id,$uid]);
        }
        try{audit_event($uid,'post.edited',['post_id'=>$id,'field'=>$field]);}catch(Throwable $e){error_log('Circle mobile post audit: '.$e->getMessage());}mobile_reply(['ok'=>true,'post_id'=>$id]);
    }
    if($route==='post-delete'){
        mobile_method('POST');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$id=(int)($d['post_id']??0);$post=mobile_post_access($id,$uid);
        if((int)$post['author_id']!==$uid)mobile_fail('FORBIDDEN',403);
        db()->prepare('DELETE FROM social_posts WHERE id=? AND author_id=?')->execute([$id,$uid]);
        try{audit_event($uid,'post.deleted',['post_id'=>$id]);}catch(Throwable $e){error_log('Circle mobile post audit: '.$e->getMessage());}mobile_reply(['ok'=>true,'post_id'=>$id]);
    }
    if($route==='post-repost'){
        mobile_method('POST');if(!feature_enabled('post-interactions'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$id=(int)($d['post_id']??0);mobile_post_access($id,$uid);
        $q=db()->prepare('SELECT 1 FROM social_post_reposts WHERE post_id=? AND user_id=?');$q->execute([$id,$uid]);
        $active=(bool)$q->fetchColumn();
        if($active)db()->prepare('DELETE FROM social_post_reposts WHERE post_id=? AND user_id=?')->execute([$id,$uid]);
        else db()->prepare('INSERT IGNORE INTO social_post_reposts(post_id,user_id,created_at) VALUES(?,?,NOW())')->execute([$id,$uid]);
        $q=db()->prepare('SELECT COUNT(*) FROM social_post_reposts WHERE post_id=?');$q->execute([$id]);
        mobile_reply(['ok'=>true,'post_id'=>$id,'reposted'=>!$active,'total'=>(int)$q->fetchColumn()]);
    }
    if($route==='post-pin'){
        mobile_method('POST');if(!feature_enabled('social-feed'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$id=(int)($d['post_id']??0);$post=mobile_post_access($id,$uid);
        // Profile pinning only; community moderators use web controls until their roles API is exposed.
        if((int)$post['author_id']!==$uid||$post['scope_type']!=='USER')mobile_fail('FORBIDDEN',403);
        db()->prepare('UPDATE social_posts SET is_pinned=IF(is_pinned=1,0,1),updated_at=NOW() WHERE id=? AND author_id=?')->execute([$id,$uid]);
        $q=db()->prepare('SELECT is_pinned FROM social_posts WHERE id=?');$q->execute([$id]);
        mobile_reply(['ok'=>true,'post_id'=>$id,'is_pinned'=>(bool)$q->fetchColumn()]);
    }
    if($route==='post-comment-delete'){
        mobile_method('POST');if(!feature_enabled('post-interactions'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$id=(int)($d['comment_id']??0);
        $q=db()->prepare('SELECT id,post_id,user_id FROM social_post_comments WHERE id=? LIMIT 1');$q->execute([$id]);$c=$q->fetch();
        if(!$c)mobile_fail('NOT_FOUND',404);
        mobile_post_access((int)$c['post_id'],$uid);
        if((int)$c['user_id']!==$uid)mobile_fail('FORBIDDEN',403);
        db()->beginTransaction();
        try{
            db()->prepare('UPDATE social_post_comments SET parent_comment_id=NULL WHERE parent_comment_id=? AND post_id=?')->execute([$id,(int)$c['post_id']]);
            db()->prepare('DELETE FROM social_post_comments WHERE id=? AND user_id=?')->execute([$id,$uid]);
            db()->commit();
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        try{audit_event($uid,'comment.deleted',['comment_id'=>$id]);}catch(Throwable $e){error_log('Circle mobile comment audit: '.$e->getMessage());}mobile_reply(['ok'=>true,'post_id'=>(int)$c['post_id']]);
    }
    if($route==='post-like'){
        mobile_method('POST');if(!feature_enabled('post-interactions'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$id=(int)($data['post_id']??0);mobile_post_access($id,$uid);
        $q=db()->prepare("SELECT 1 FROM social_post_reactions WHERE post_id=? AND user_id=? AND reaction='LIKE'");$q->execute([$id,$uid]);
        if($q->fetchColumn())db()->prepare('DELETE FROM social_post_reactions WHERE post_id=? AND user_id=?')->execute([$id,$uid]);
        else db()->prepare("INSERT INTO social_post_reactions(post_id,user_id,reaction,created_at) VALUES(?,?,'LIKE',NOW()) ON DUPLICATE KEY UPDATE reaction='LIKE',created_at=NOW()")->execute([$id,$uid]);
        mobile_reply(['ok'=>true,'stats'=>mobile_post_stats($id,$uid)]);
    }
    if($route==='post-comments'){
        mobile_method('GET');if(!feature_enabled('post-interactions'))mobile_fail('FEATURE_DISABLED',403);
        $id=(int)($_GET['post_id']??0);mobile_post_access($id,$uid);
        $q=db()->prepare('SELECT c.id,c.body,c.parent_comment_id,c.created_at,u.id AS author_id,u.username,p.display_name,p.avatar_path FROM social_post_comments c JOIN users u ON u.id=c.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE c.post_id=? ORDER BY c.id DESC LIMIT 80');$q->execute([$id]);$items=[];
        foreach($q->fetchAll() as $c)$items[]=['id'=>(int)$c['id'],'body'=>$c['body'],'parent_comment_id'=>$c['parent_comment_id']?(int)$c['parent_comment_id']:null,'mine'=>(int)$c['author_id']===$uid,'created_at'=>$c['created_at'],'author'=>mobile_profile(['id'=>$c['author_id'],'username'=>$c['username'],'display_name'=>$c['display_name'],'avatar_path'=>$c['avatar_path']])];
        mobile_reply(['ok'=>true,'items'=>$items]);
    }
    if($route==='post-comment'){
        mobile_method('POST');if(!feature_enabled('post-interactions'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$id=(int)($data['post_id']??0);$post=mobile_post_access($id,$uid);
        if(!(int)($post['comments_enabled']??1))mobile_fail('COMMENTS_DISABLED',403);
        $body=trim((string)($data['body']??''));$parent=max(0,(int)($data['parent_comment_id']??0));
        if($body===''||mb_strlen($body)>1200)mobile_fail('INVALID_COMMENT',422);
        if($parent){$q=db()->prepare('SELECT 1 FROM social_post_comments WHERE id=? AND post_id=?');$q->execute([$parent,$id]);if(!$q->fetchColumn())mobile_fail('PARENT_NOT_FOUND',404);}
        if($blocked=circle_trust_preflight_error($body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
        db()->prepare('INSERT INTO social_post_comments(post_id,user_id,body,parent_comment_id,created_at) VALUES(?,?,?,?,NOW())')->execute([$id,$uid,$body,$parent?:null]);mobile_reply(['ok'=>true,'comment_id'=>(int)db()->lastInsertId(),'stats'=>mobile_post_stats($id,$uid)],201);
    }
    if($route==='dm-open'){
        mobile_method('POST');if(!feature_enabled('direct-messages'))mobile_fail('FEATURE_DISABLED',403);
        $d=mobile_json();$target=(int)($d['user_id']??0);
        if($target<1||$target===$uid)mobile_fail('INVALID_USER',422);
        db()->beginTransaction();
        try{
            $q=db()->prepare("SELECT id FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1 FOR UPDATE");
            $q->execute([$uid,$target,$target,$uid]);if(!$q->fetchColumn()){db()->rollBack();mobile_fail('FRIENDS_ONLY',403);}
            $q=db()->prepare('SELECT a.conversation_id FROM dm_members a JOIN dm_members b ON b.conversation_id=a.conversation_id AND b.user_id=? WHERE a.user_id=? AND (SELECT COUNT(*) FROM dm_members c WHERE c.conversation_id=a.conversation_id)=2 ORDER BY a.conversation_id DESC LIMIT 1');
            $q->execute([$target,$uid]);$id=(int)($q->fetchColumn()?:0);
            if(!$id){
                db()->prepare('INSERT INTO dm_conversations(created_at,updated_at) VALUES(NOW(),NOW())')->execute();$id=(int)db()->lastInsertId();
                db()->prepare('INSERT INTO dm_members(conversation_id,user_id,joined_at) VALUES(?,?,NOW()),(?,?,NOW())')->execute([$id,$uid,$id,$target]);
            }
            db()->commit();
            mobile_reply(['ok'=>true,'conversation_id'=>$id]);
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
    }
    if($route==='conversations'){
        mobile_method('GET');$q=db()->prepare("SELECT d.id,d.updated_at, (SELECT CASE WHEN TRIM(COALESCE(m.body,''))='' AND EXISTS(SELECT 1 FROM dm_attachments a WHERE a.message_id=m.id) THEN 'Вложение' ELSE COALESCE(m.body,'') END FROM dm_messages m WHERE m.conversation_id=d.id ORDER BY m.id DESC LIMIT 1) AS last_message, u.id AS peer_id,u.username,p.display_name,p.avatar_path FROM dm_conversations d JOIN dm_members mine ON mine.conversation_id=d.id AND mine.user_id=? JOIN dm_members peer ON peer.conversation_id=d.id AND peer.user_id<>? JOIN users u ON u.id=peer.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE (SELECT COUNT(*) FROM dm_members x WHERE x.conversation_id=d.id)=2 ORDER BY d.updated_at DESC LIMIT 100");$q->execute([$uid,$uid]);$items=[];foreach($q->fetchAll() as $r)$items[]=['id'=>(int)$r['id'],'last_message'=>$r['last_message']??'','updated_at'=>$r['updated_at'],'peer'=>mobile_profile(['id'=>$r['peer_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])];mobile_reply(['ok'=>true,'items'=>$items]);
    }
    if($route==='trust-report-dm'){
        mobile_method('POST');$data=mobile_json();
        $messageId=(int)($data['message_id']??0);$reason=mb_substr(trim((string)($data['reason']??'')),0,500);
        if($messageId<1||mb_strlen($reason)<5)mobile_fail('INVALID_REPORT',422);
        $limit=db()->prepare("SELECT COUNT(*) FROM circle_trust_cases WHERE reporter_id=? AND source_type='DM_REPORT' AND created_at>DATE_SUB(NOW(),INTERVAL 1 DAY)");
        $limit->execute([$uid]);if((int)$limit->fetchColumn()>=5)mobile_fail('RATE_LIMIT',429);
        $q=db()->prepare('SELECT m.id,m.user_id,m.body FROM dm_messages m JOIN dm_members cm ON cm.conversation_id=m.conversation_id AND cm.user_id=? WHERE m.id=?');
        $q->execute([$uid,$messageId]);$msg=$q->fetch();
        if(!$msg||(int)$msg['user_id']===$uid)mobile_fail('FORBIDDEN',403);
        $existing=db()->prepare("SELECT id FROM circle_trust_cases WHERE source_type='DM_REPORT' AND source_id=? AND reporter_id=? LIMIT 1");
        $existing->execute([$messageId,$uid]);if($existing->fetchColumn())mobile_fail('ALREADY_REPORTED',409);
        db()->prepare("INSERT INTO circle_trust_cases(source_type,source_id,rule_id,target_user_id,reporter_id,excerpt,status,resolution_note,created_at) VALUES('DM_REPORT',?,NULL,?,?,?,'OPEN',?,NOW())")
            ->execute([$messageId,(int)$msg['user_id'],$uid,mb_substr((string)$msg['body'],0,240),$reason]);
        audit_event($uid,'trust.dm_reported',['message_id'=>$messageId]);mobile_reply(['ok'=>true]);
    }
    if($route==='message-reaction'){
        mobile_method('POST');
        if(!feature_enabled('direct-messages'))mobile_fail('FEATURE_DISABLED',403);
        $data=mobile_json();$conversationId=(int)($data['conversation_id']??0);
        $messageId=(int)($data['message_id']??0);$emoji=(string)($data['emoji']??'');
        mobile_dm_access($conversationId,$uid);
        // Small, fixed palette. No arbitrary strings are inserted into the reactions table.
        if(!in_array($emoji,['❤️','👍','😂','🔥','😮','😢','👏','🎉'],true))mobile_fail('INVALID_REACTION',422);
        $q=db()->prepare('SELECT id FROM dm_messages WHERE conversation_id=? AND id=? LIMIT 1');
        $q->execute([$conversationId,$messageId]);if(!$q->fetchColumn())mobile_fail('MESSAGE_NOT_FOUND',404);
        $q=db()->prepare('SELECT 1 FROM dm_message_reactions WHERE message_id=? AND user_id=? AND emoji=?');
        $q->execute([$messageId,$uid,$emoji]);
        $active=false;
        if($q->fetchColumn()){
            db()->prepare('DELETE FROM dm_message_reactions WHERE message_id=? AND user_id=? AND emoji=?')->execute([$messageId,$uid,$emoji]);
        }else{
            db()->prepare('INSERT IGNORE INTO dm_message_reactions(message_id,user_id,emoji,created_at) VALUES(?,?,?,NOW())')->execute([$messageId,$uid,$emoji]);
            $active=true;
        }
        $sum=db()->prepare('SELECT emoji,COUNT(*) AS total,MAX(CASE WHEN user_id=? THEN 1 ELSE 0 END) AS mine FROM dm_message_reactions WHERE message_id=? GROUP BY emoji');
        $sum->execute([$uid,$messageId]);$items=[];
        foreach($sum->fetchAll() as $r)$items[]=['emoji'=>$r['emoji'],'total'=>(int)$r['total'],'mine'=>(bool)$r['mine']];
        mobile_reply(['ok'=>true,'active'=>$active,'reactions'=>$items]);
    }
    if($route==='messages' || $route==='message-upload'){
        $conversationId=(int)($_GET['conversation_id']??0);
        mobile_dm_access($conversationId,$uid);
        if($route==='messages' && ($_SERVER['REQUEST_METHOD']??'')==='GET'){
            $before=max(0,(int)($_GET['before']??0));$after=max(0,(int)($_GET['after']??0));
            if($before>0&&$after>0)mobile_fail('INVALID_CURSOR',400);
            if($after>0){
                $q=db()->prepare('SELECT id,user_id,body,created_at,reply_to_id,(SELECT body FROM dm_messages r WHERE r.id=dm_messages.reply_to_id AND r.conversation_id=dm_messages.conversation_id) AS reply_body FROM dm_messages WHERE conversation_id=? AND id>? ORDER BY id ASC LIMIT 100');
                $q->execute([$conversationId,$after]);$items=$q->fetchAll();
                if($items)mobile_mark_dm_read($conversationId,$uid,(int)end($items)['id']);
                mobile_reply(['ok'=>true,'items'=>mobile_attachment_rows($items),'has_more'=>count($items)===100]);
            }
            $sql='SELECT id,user_id,body,created_at,reply_to_id,(SELECT body FROM dm_messages r WHERE r.id=dm_messages.reply_to_id AND r.conversation_id=dm_messages.conversation_id) AS reply_body FROM dm_messages WHERE conversation_id=?'.($before>0?' AND id<?':'').' ORDER BY id DESC LIMIT 51';
            $q=db()->prepare($sql);$q->execute($before>0?[$conversationId,$before]:[$conversationId]);$items=$q->fetchAll();
            $hasMore=count($items)>50;if($hasMore)array_pop($items);
            $items=array_reverse($items);
            // Mark as read only when opening the newest page, not while scrolling old history.
            if(!$before && $items){
                $lastId=(int)end($items)['id'];
                mobile_mark_dm_read($conversationId,$uid,$lastId);
            }
            mobile_reply(['ok'=>true,'items'=>mobile_attachment_rows($items),'has_more'=>$hasMore,'next_before'=>$items?(int)$items[0]['id']:null]);
        }
        mobile_method('POST');
        $files=[];$kind='FILE';
        if($route==='message-upload'){
            if(!feature_enabled('message-attachments'))mobile_fail('FEATURE_DISABLED',403);
            // Keep one attachment per request; clients may send multiple independent messages.
            $file=$_FILES['attachment']??null;
            if(!is_array($file)||(int)($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK)mobile_fail('UPLOAD_FAILED',422);
            $kind=strtoupper((string)($_POST['kind']??'FILE'));
            if(!in_array($kind,['VOICE','FILE'],true))mobile_fail('INVALID_ATTACHMENT',422);
            $size=(int)($file['size']??0);
            if($size<1||$size>30*1024*1024||!is_uploaded_file((string)$file['tmp_name']))mobile_fail('INVALID_ATTACHMENT',422);
            $finfo=(new finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']);
            $types=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp','image/gif'=>'gif','video/mp4'=>'mp4','video/webm'=>'webm'];
            if($kind==='VOICE'){
                if(!feature_enabled('voice-messages'))mobile_fail('FEATURE_DISABLED',403);
                $finfo=mobile_detect_voice_mime((string)$file['tmp_name'],(string)$finfo);
                $types=['audio/webm'=>'webm','audio/ogg'=>'ogg','audio/mp4'=>'m4a','audio/mpeg'=>'mp3','audio/wav'=>'wav'];
            }elseif(!feature_enabled('message-media-preview'))mobile_fail('FEATURE_DISABLED',403);
            if(!$finfo||!isset($types[$finfo]))mobile_fail('UNSUPPORTED_MEDIA',415);
            if(str_starts_with((string)$finfo,'image/')&&!getimagesize($file['tmp_name']))mobile_fail('INVALID_ATTACHMENT',422);
            $dir=dirname(__DIR__).'/uploads/messages';
            if(!is_dir($dir)&&!mkdir($dir,0755,true)&&!is_dir($dir))mobile_fail('UPLOAD_FAILED',500);
            $stored=bin2hex(random_bytes(20)).'.'.$types[$finfo];
            if(!move_uploaded_file((string)$file['tmp_name'],$dir.'/'.$stored))mobile_fail('UPLOAD_FAILED',500);
            $files=[[$stored,mb_substr(basename((string)($file['name']??'file')),0,180),$finfo,$size,$kind]];
            $body=trim((string)($_POST['body']??''));$replyTo=(int)($_POST['reply_to_id']??0);
        }else{
            $data=mobile_json();$body=trim((string)($data['body']??''));$replyTo=(int)($data['reply_to_id']??0);
        }
        if($replyTo>0){
            if(!feature_enabled('message-replies-mentions')){foreach($files as $file)@unlink(dirname(__DIR__).'/uploads/messages/'.$file[0]);mobile_fail('FEATURE_DISABLED',403);}
            $replyQ=db()->prepare('SELECT id FROM dm_messages WHERE conversation_id=? AND id=?');
            $replyQ->execute([$conversationId,$replyTo]);
            if(!$replyQ->fetchColumn()){foreach($files as $file)@unlink(dirname(__DIR__).'/uploads/messages/'.$file[0]);mobile_fail('REPLY_NOT_FOUND',422);}
        }else $replyTo=null;
        if(($body===''&&!$files)||mb_strlen($body)>10000){foreach($files as $file)@unlink(dirname(__DIR__).'/uploads/messages/'.$file[0]);mobile_fail('INVALID_MESSAGE',422);}
        try{
            db()->beginTransaction();
            db()->prepare('INSERT INTO dm_messages(conversation_id,user_id,body,reply_to_id,created_at) VALUES(?,?,?,?,NOW())')->execute([$conversationId,$uid,$body,$replyTo]);
            $mid=(int)db()->lastInsertId();
            foreach($files as $file){db()->prepare('INSERT INTO dm_attachments(message_id,uploader_id,original_name,stored_name,mime_type,file_size,kind,created_at) VALUES(?,?,?,?,?,?,?,NOW())')->execute([$mid,$uid,$file[1],$file[0],$file[2],$file[3],$file[4]]);}
            db()->prepare('UPDATE dm_conversations SET updated_at=NOW() WHERE id=?')->execute([$conversationId]);db()->commit();
        }catch(Throwable $err){if(db()->inTransaction())db()->rollBack();foreach($files as $file)@unlink(dirname(__DIR__).'/uploads/messages/'.$file[0]);throw $err;}
        $peer=db()->prepare('SELECT user_id FROM dm_members WHERE conversation_id=? AND user_id<>? LIMIT 1');
        $peer->execute([$conversationId,$uid]);$recipient=(int)$peer->fetchColumn();
        if($recipient>0){try{notify_user($recipient,'dm_message',$uid,['conversation_id'=>$conversationId]);}catch(Throwable $notifyErr){error_log('Circle mobile DM notification: '.$notifyErr->getMessage());}}
        mobile_reply(['ok'=>true,'message'=>['id'=>$mid,'user_id'=>$uid,'body'=>$body]],201);
    }
    require_once __DIR__ . '/desktop_ext.php';
    circle_desktop_dispatch($route,$actor);
    mobile_fail('NOT_FOUND',404);
}catch(Throwable $e){error_log('Circle mobile API: '.$e->getMessage());mobile_fail('SERVER_ERROR',500);}
