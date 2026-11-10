<?php
declare(strict_types=1);
/** Circle Desktop API extension — authenticated by mobile.php before dispatch. */
function desktop_input(): array { mobile_method('POST'); return mobile_json(); }
function desktop_feature(string $feature): void { if (!feature_enabled($feature)) mobile_fail('FEATURE_DISABLED',403); }
function desktop_admin(array $actor): void {
    if (!in_array((string)($actor['platform_role']??''),['OWNER','ADMIN'],true)) mobile_fail('FORBIDDEN',403);
}
function desktop_manage(int $community, int $uid, string $permission='MANAGE_COMMUNITY'): void {
    if ($community<1 || circle_is_official($community) || !has_community_permission($community,$uid,$permission)) mobile_fail('FORBIDDEN',403);
}
function desktop_member(int $community,int $uid): void {
    if ($community<1 || !is_community_member($community,$uid)) mobile_fail('FORBIDDEN',403);
}
function desktop_channel(int $channel,int $uid,bool $manage=false): array {
    $c=mobile_channel_access($channel,$uid);
    if($manage)desktop_manage((int)$c['community_id'],$uid,'MANAGE_CHANNELS');
    return $c;
}
function desktop_positive(mixed $v): int {return max(0,(int)$v);}
function desktop_valid_channel(string $name): bool {return (bool)preg_match('/^[\pL\pN_-]{2,60}$/u',$name);}
function desktop_response_rows(PDOStatement $q): array {return $q->fetchAll(PDO::FETCH_ASSOC);}

/** API-safe media storage: index.php's helper is unavailable to api/mobile.php. */
function desktop_store_community_image(array $upload, int $max): array {
    $size=(int)($upload['size']??0);
    $tmp=(string)($upload['tmp_name']??'');
    if(($upload['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK || $size<1 || $size>$max || !$tmp || !is_uploaded_file($tmp))
        mobile_fail('INVALID_MEDIA',422);
    $mime=(new finfo(FILEINFO_MIME_TYPE))->file($tmp);
    $ext=['image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp','image/gif'=>'gif'][$mime]??null;
    if($ext===null || !getimagesize($tmp))mobile_fail('UNSUPPORTED_MEDIA',415);
    $dir=storage_dir().'/circle-media';
    if(!is_dir($dir) && !mkdir($dir,0700,true) && !is_dir($dir))mobile_fail('STORAGE_UNAVAILABLE',503);
    $name=bin2hex(random_bytes(24)).'.'.$ext;
    if(!move_uploaded_file($tmp,$dir.'/'.$name))mobile_fail('UPLOAD_FAILED',500);
    return ['name'=>$name,'mime'=>$mime];
}
function desktop_permission_set(mixed $permissions,array $allowed): bool {
    return is_array($permissions) && array_is_list($permissions)
        && count($permissions)<=count($allowed)
        && count($permissions)===count(array_unique($permissions))
        && count(array_filter($permissions,static fn($p)=>is_string($p)&&in_array($p,$allowed,true)))===count($permissions);
}

function circle_desktop_dispatch(string $route,array $actor): void {
    if(!str_starts_with($route,'desktop-'))return;
    $uid=(int)$actor['id'];
    // Account security — server retains ownership of authorization decisions.
    if($route==='desktop-security'){
        mobile_method('GET');desktop_feature('account-security');
        $q=db()->prepare('SELECT username,email,totp_enabled FROM users WHERE id=?');$q->execute([$uid]);$account=$q->fetch(PDO::FETCH_ASSOC);
        $q=db()->prepare('SELECT id,device_label,created_at,last_seen_at FROM user_sessions WHERE user_id=? AND revoked_at IS NULL ORDER BY last_seen_at DESC LIMIT 50');$q->execute([$uid]);$sessions=desktop_response_rows($q);
        $q=db()->prepare('SELECT id,device_label,created_at,last_used_at FROM mobile_access_tokens WHERE user_id=? AND revoked_at IS NULL AND expires_at>NOW() ORDER BY id DESC LIMIT 50');$q->execute([$uid]);$devices=desktop_response_rows($q);
        foreach($devices as &$device)$device['current']=(int)$device['id']===(int)$actor['token_id'];unset($device);
        mobile_reply(['ok'=>true,'account'=>$account,'sessions'=>$sessions,'devices'=>$devices]);
    }
    if($route==='desktop-password-change'){
        desktop_feature('account-security');$d=desktop_input();$old=(string)($d['current_password']??'');$new=(string)($d['new_password']??'');
        if(strlen($old)>512||strlen($new)<10||strlen($new)>512)mobile_fail('INVALID_PASSWORD',422);
        $q=db()->prepare('SELECT password_hash FROM users WHERE id=?');$q->execute([$uid]);if(!password_verify($old,(string)$q->fetchColumn()))mobile_fail('INVALID_PASSWORD',403);
        db()->beginTransaction();try{
            db()->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash($new,PASSWORD_ARGON2ID),$uid]);
            db()->prepare('UPDATE user_sessions SET revoked_at=NOW() WHERE user_id=? AND revoked_at IS NULL')->execute([$uid]);
            db()->prepare('DELETE FROM circle_remember_tokens WHERE user_id=?')->execute([$uid]);
            db()->prepare('UPDATE mobile_access_tokens SET revoked_at=NOW() WHERE user_id=? AND id<>? AND revoked_at IS NULL')->execute([$uid,(int)$actor['token_id']]);
            db()->commit();
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'account.desktop_password_changed');mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-username-change'){
        desktop_feature('profiles');$d=desktop_input();$name=trim((string)($d['username']??''));$pass=(string)($d['password']??'');
        if(!preg_match('/^[A-Za-z0-9_]{3,24}$/D',$name))mobile_fail('INVALID_USERNAME',422);
        $q=db()->prepare('SELECT password_hash FROM users WHERE id=?');$q->execute([$uid]);if(!password_verify($pass,(string)$q->fetchColumn()))mobile_fail('INVALID_PASSWORD',403);
        $q=db()->prepare('SELECT id FROM users WHERE LOWER(username)=LOWER(?) AND id<>? LIMIT 1');$q->execute([$name,$uid]);if($q->fetchColumn())mobile_fail('USERNAME_TAKEN',409);
        try{db()->prepare('UPDATE users SET username=? WHERE id=?')->execute([$name,$uid]);}catch(PDOException $e){if(($e->errorInfo[1]??0)==1062)mobile_fail('USERNAME_TAKEN',409);throw $e;}
        audit_event($uid,'account.desktop_username_changed');mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-device-revoke'){
        desktop_feature('account-security');$d=desktop_input();$id=desktop_positive($d['id']??0);$kind=(string)($d['kind']??'');
        if($id<1||!in_array($kind,['web','mobile'],true))mobile_fail('INVALID_DEVICE',422);
        if($kind==='web'){
            db()->prepare('DELETE FROM circle_remember_tokens WHERE user_id=? AND device_hash IN (SELECT device_hash FROM user_sessions WHERE id=? AND user_id=? AND device_hash IS NOT NULL)')->execute([$uid,$id,$uid]);
            db()->prepare('UPDATE user_sessions SET revoked_at=NOW() WHERE id=? AND user_id=?')->execute([$id,$uid]);
        }else{
            if($id===(int)$actor['token_id'])mobile_fail('CURRENT_DEVICE',422);
            db()->prepare('UPDATE mobile_access_tokens SET revoked_at=NOW() WHERE id=? AND user_id=?')->execute([$id,$uid]);
        }
        audit_event($uid,'account.desktop_device_revoked',['kind'=>$kind]);mobile_reply(['ok'=>true]);
    }
    // Invites-only community membership, consistent with the website.
    if($route==='desktop-totp-start'){
        desktop_feature('account-security');$d=desktop_input();$password=(string)($d['password']??'');
        $q=db()->prepare('SELECT password_hash,totp_enabled FROM users WHERE id=?');$q->execute([$uid]);$u=$q->fetch();
        if(!$u||!password_verify($password,(string)$u['password_hash']))mobile_fail('INVALID_PASSWORD',403);
        if((int)$u['totp_enabled'])mobile_fail('TOTP_ALREADY_ENABLED',409);
        $secret=base32_encode_krug(random_bytes(20));$challenge=encrypt_secret(json_encode(['uid'=>$uid,'secret'=>$secret,'exp'=>time()+600]));
        mobile_reply(['ok'=>true,'secret'=>$secret,'challenge'=>$challenge,'expires_in'=>600,'issuer'=>'Circle','account'=>(string)$actor['username']]);
    }
    if($route==='desktop-totp-enable'){
        desktop_feature('account-security');$d=desktop_input();$challenge=(string)($d['challenge']??'');$code=trim((string)($d['code']??''));
        if(strlen($challenge)>4096||strlen($code)>10||mobile_limited(mobile_limiter_key()))mobile_fail('RATE_LIMIT',429);
        try{$payload=json_decode(decrypt_secret($challenge),true);}catch(Throwable $e){mobile_fail('INVALID_CHALLENGE',422);}
        if(!is_array($payload)||($payload['uid']??0)!==$uid||($payload['exp']??0)<time()||!is_string($payload['secret']??null))mobile_fail('INVALID_CHALLENGE',422);
        if(!totp_verify($payload['secret'],$code)){mobile_failed_login(mobile_limiter_key());mobile_fail('INVALID_TOTP',422);}
        $recovery=[];db()->beginTransaction();try{
            $q=db()->prepare('SELECT totp_enabled FROM users WHERE id=? FOR UPDATE');$q->execute([$uid]);if((int)$q->fetchColumn()){db()->rollBack();mobile_fail('TOTP_ALREADY_ENABLED',409);}
            db()->prepare('UPDATE users SET totp_secret=?,totp_enabled=1 WHERE id=?')->execute([encrypt_secret($payload['secret']),$uid]);
            db()->prepare('DELETE FROM totp_recovery_codes WHERE user_id=?')->execute([$uid]);
            $q=db()->prepare('INSERT INTO totp_recovery_codes(user_id,code_hash,created_at) VALUES(?,?,NOW())');
            for($i=0;$i<8;$i++){$plain=strtoupper(bin2hex(random_bytes(5)));$recovery[]=$plain;$q->execute([$uid,hash_hmac('sha256',$plain,setting('app_key'))]);}
            db()->commit();
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'account.desktop_totp_enabled');mobile_reply(['ok'=>true,'recovery_codes'=>$recovery]);
    }
    if($route==='desktop-totp-disable'){
        desktop_feature('account-security');$d=desktop_input();$password=(string)($d['password']??'');$code=(string)($d['code']??'');
        if(mobile_limited(mobile_limiter_key()))mobile_fail('RATE_LIMIT',429);
        $q=db()->prepare('SELECT password_hash,totp_secret,totp_enabled FROM users WHERE id=?');$q->execute([$uid]);$u=$q->fetch();
        if(!$u||!(int)$u['totp_enabled']||!password_verify($password,(string)$u['password_hash'])||!totp_verify(decrypt_secret((string)$u['totp_secret']),$code)){mobile_failed_login(mobile_limiter_key());mobile_fail('INVALID_CREDENTIALS',403);}
        db()->beginTransaction();try{db()->prepare('UPDATE users SET totp_secret=NULL,totp_enabled=0 WHERE id=?')->execute([$uid]);db()->prepare('DELETE FROM totp_recovery_codes WHERE user_id=?')->execute([$uid]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'account.desktop_totp_disabled');mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-community-create'){
        desktop_feature('communities');$d=desktop_input();$name=trim((string)($d['name']??''));$desc=trim((string)($d['description']??''));
        if(mb_strlen($name)<2||mb_strlen($name)>80||mb_strlen($desc)>500)mobile_fail('INVALID_COMMUNITY',422);
        $slug=strtolower(trim((string)preg_replace('/[^a-z0-9]+/i','-',(string)iconv('UTF-8','ASCII//TRANSLIT//IGNORE',$name)),'-'));
        if($slug==='')$slug='circle-group';$slug=substr($slug,0,70).'-'.bin2hex(random_bytes(4));
        db()->beginTransaction();try{
            db()->prepare("INSERT INTO communities(name,description,slug,owner_id,accent_color,news_enabled,chat_enabled,voice_enabled,created_at) VALUES(?,?,?,?,'#C6A15B',1,1,1,NOW())")->execute([$name,$desc,$slug,$uid]);
            $id=(int)db()->lastInsertId();db()->prepare("INSERT INTO community_members(community_id,user_id,member_role,joined_at) VALUES(?,?,'OWNER',NOW())")->execute([$id,$uid]);
            db()->prepare('INSERT INTO channels(community_id,name,created_at) VALUES(?,?,NOW())')->execute([$id,'общий']);db()->commit();
        }catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'community.desktop_created',['community_id'=>$id]);mobile_reply(['ok'=>true,'id'=>$id],201);
    }
    if($route==='desktop-community-leave'){
        desktop_feature('communities');$d=desktop_input();$id=desktop_positive($d['community_id']??0);
        if(circle_is_official($id))mobile_fail('OFFICIAL_COMMUNITY',403);desktop_member($id,$uid);
        $q=db()->prepare('SELECT member_role FROM community_members WHERE community_id=? AND user_id=?');$q->execute([$id,$uid]);if($q->fetchColumn()==='OWNER')mobile_fail('TRANSFER_OWNERSHIP_FIRST',409);
        db()->beginTransaction();try{db()->prepare('DELETE FROM community_role_members WHERE community_id=? AND user_id=?')->execute([$id,$uid]);db()->prepare('DELETE FROM community_members WHERE community_id=? AND user_id=?')->execute([$id,$uid]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'community.desktop_left',['community_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-community-panel'){
        mobile_method('GET');$id=desktop_positive($_GET['community_id']??0);desktop_member($id,$uid);
        $manage=can_manage_community($id,$uid)&&!circle_is_official($id);
        $appearanceQ=db()->prepare('SELECT name,description,news_enabled,chat_enabled,voice_enabled,banner_zoom,banner_pos_x,banner_pos_y FROM communities WHERE id=?');$appearanceQ->execute([$id]);
        $appearance=$appearanceQ->fetch(PDO::FETCH_ASSOC)?:[];
        $channels=db()->prepare('SELECT id,name,slowmode_seconds FROM channels WHERE community_id=? ORDER BY id');$channels->execute([$id]);
        $q=db()->prepare('SELECT id,name,color,badge_icon,permissions FROM community_roles WHERE community_id=? ORDER BY position,id');$q->execute([$id]);$roles=desktop_response_rows($q);
        foreach($roles as &$role){$role['permissions']=json_decode((string)$role['permissions'],true)?:[];}unset($role);
        $voice=db()->prepare('SELECT id,name,channel_type,is_locked FROM community_voice_channels WHERE community_id=? AND (expires_at IS NULL OR expires_at>NOW()) AND is_deleting=0 ORDER BY id');$voice->execute([$id]);
        $members=db()->prepare('SELECT u.id,u.username,p.display_name,cm.member_role FROM community_members cm JOIN users u ON u.id=cm.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE cm.community_id=? ORDER BY FIELD(cm.member_role,\'OWNER\',\'ADMIN\',\'MEMBER\'),u.id LIMIT 150');$members->execute([$id]);
        $invites=[];$automod=[];
        if($manage){$q=db()->prepare('SELECT id,expires_at,max_uses,uses,revoked_at,created_at FROM community_invites WHERE community_id=? ORDER BY id DESC LIMIT 50');$q->execute([$id]);$invites=desktop_response_rows($q);}
        if(has_community_permission($id,$uid,'MANAGE_MESSAGES')){$q=db()->prepare('SELECT enabled,block_invites,block_external_links,slowmode_seconds FROM community_automod WHERE community_id=?');$q->execute([$id]);$automod=$q->fetch(PDO::FETCH_ASSOC)?:[];}
        mobile_reply(['ok'=>true,'can_manage'=>$manage,'can_manage_channels'=>has_community_permission($id,$uid,'MANAGE_CHANNELS'),'can_manage_messages'=>has_community_permission($id,$uid,'MANAGE_MESSAGES'),'appearance'=>$appearance,'channels'=>desktop_response_rows($channels),'voice_channels'=>desktop_response_rows($voice),'members'=>desktop_response_rows($members),'roles'=>$roles,'invites'=>$invites,'automod'=>$automod]);
    }
    if($route==='desktop-community-appearance'){
        $d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);
        $name=trim((string)($d['name']??''));$desc=trim((string)($d['description']??''));
        if(mb_strlen($name)<2||mb_strlen($name)>80||mb_strlen($desc)>500)mobile_fail('INVALID_COMMUNITY',422);
        $flags=[];foreach(['news_enabled','chat_enabled','voice_enabled'] as $key){if(!isset($d[$key])||!is_bool($d[$key]))mobile_fail('INVALID_SETTINGS',422);$flags[]=$d[$key]?1:0;}
        $zoom=min(300,max(100,(int)($d['banner_zoom']??100)));$x=min(100,max(0,(int)($d['banner_pos_x']??50)));$y=min(100,max(0,(int)($d['banner_pos_y']??50)));
        db()->prepare('UPDATE communities SET name=?,description=?,news_enabled=?,chat_enabled=?,voice_enabled=?,banner_zoom=?,banner_pos_x=?,banner_pos_y=? WHERE id=?')->execute(array_merge([$name,$desc],$flags,[$zoom,$x,$y,$id]));
        audit_event($uid,'community.desktop_appearance',['community_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-community-image-upload'){
        desktop_feature('communities');mobile_method('POST');$id=desktop_positive($_POST['community_id']??0);desktop_manage($id,$uid);
        $kind=(string)($_POST['kind']??'');if(!in_array($kind,['icon','banner'],true))mobile_fail('INVALID_MEDIA',422);
        $file=$_FILES['attachment']??null;if(!is_array($file)||($file['error']??UPLOAD_ERR_NO_FILE)!==UPLOAD_ERR_OK)mobile_fail('UPLOAD_FAILED',422);
        $max=$kind==='icon'?5*1024*1024:15*1024*1024;
        if((int)($file['size']??0)<1||(int)($file['size']??0)>$max||!is_uploaded_file((string)($file['tmp_name']??'')))mobile_fail('INVALID_MEDIA',422);
        $mime=(new finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']);
        if(!in_array($mime,$kind==='icon'?['image/jpeg','image/png','image/webp']:['image/jpeg','image/png','image/webp','image/gif'],true)||!getimagesize($file['tmp_name']))mobile_fail('UNSUPPORTED_MEDIA',415);
        try{$media=desktop_store_community_image($file,$max);}catch(Throwable $e){mobile_fail('UPLOAD_FAILED',422);}
        $col=$kind==='icon'?'icon':'banner';
        try{db()->prepare("UPDATE communities SET {$col}_path=?,{$col}_mime=? WHERE id=?")->execute([$media['name'],$media['mime'],$id]);}
        catch(Throwable $e){@unlink(storage_dir().'/circle-media/'.$media['name']);throw $e;}
        audit_event($uid,'community.desktop_media_updated',['community_id'=>$id,'kind'=>$kind]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-voice-channel-create'){
        desktop_feature('livekit');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_member($id,$uid);
        $name=trim((string)($d['name']??''));$type=(string)($d['channel_type']??'TEMPORARY');
        $q=db()->prepare('SELECT voice_enabled FROM communities WHERE id=?');$q->execute([$id]);if(!(int)$q->fetchColumn())mobile_fail('VOICE_DISABLED',403);
        if(mb_strlen($name)<2||mb_strlen($name)>60||!in_array($type,['TEMPORARY','PERMANENT'],true))mobile_fail('INVALID_CHANNEL',422);
        $permission=$type==='PERMANENT'?'MANAGE_CHANNELS':'CREATE_TEMP_VOICE';
        if(!has_community_permission($id,$uid,$permission)||!circle_official_voice_allowed($id,$uid))mobile_fail('FORBIDDEN',403);
        $roomKey=bin2hex(random_bytes(16));$exp=$type==='TEMPORARY'?date('Y-m-d H:i:s',time()+12*3600):null;
        db()->prepare('INSERT INTO community_voice_channels(community_id,name,channel_type,room_key,created_by,created_at,expires_at) VALUES(?,?,?,?,?,NOW(),?)')->execute([$id,$name,$type,$roomKey,$uid,$exp]);
        audit_event($uid,'community.desktop_voice_created',['community_id'=>$id]);mobile_reply(['ok'=>true,'id'=>(int)db()->lastInsertId()],201);
    }
    if($route==='desktop-voice-channel-lock'){
        desktop_feature('livekit');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid,'MANAGE_CHANNELS');
        $channel=desktop_positive($d['channel_id']??0);$locked=$d['locked']??null;if(!is_bool($locked))mobile_fail('INVALID_STATE',422);
        db()->prepare('UPDATE community_voice_channels SET is_locked=? WHERE id=? AND community_id=? AND is_deleting=0')->execute([$locked?1:0,$channel,$id]);
        audit_event($uid,'community.desktop_voice_lock',['community_id'=>$id,'channel_id'=>$channel,'locked'=>$locked]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-invite-create'){
        desktop_feature('community-invites');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);
        $days=(int)($d['expires_days']??7);$max=(int)($d['max_uses']??20);
        if(!in_array($days,[0,1,7,30,90],true)||$max<1||$max>5000)mobile_fail('INVALID_INVITE',422);
        $token=bin2hex(random_bytes(24));$expires=$days===0?null:date('Y-m-d H:i:s',time()+$days*86400);
        db()->prepare('INSERT INTO community_invites(community_id,token_hash,created_by,expires_at,max_uses,created_at) VALUES(?,?,?,?,?,NOW())')->execute([$id,hash_hmac('sha256',$token,setting('app_key')),$uid,$expires,$max]);
        audit_event($uid,'community.desktop_invite_created',['community_id'=>$id]);mobile_reply(['ok'=>true,'token'=>$token,'path'=>'/index.php?page=invite&token='.$token],201);
    }
    if($route==='desktop-invite-revoke'){
        desktop_feature('community-invites');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);$invite=desktop_positive($d['invite_id']??0);
        db()->prepare('UPDATE community_invites SET revoked_at=NOW() WHERE id=? AND community_id=? AND revoked_at IS NULL')->execute([$invite,$id]);mobile_reply(['ok'=>true]);
    }
    if(in_array($route,['desktop-channel-create','desktop-channel-rename','desktop-channel-delete'],true)){
        desktop_feature('community-channels');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid,'MANAGE_CHANNELS');
        if($route==='desktop-channel-create'){
            $name=trim((string)($d['name']??''));if(!desktop_valid_channel($name))mobile_fail('INVALID_CHANNEL',422);
            db()->prepare('INSERT INTO channels(community_id,name,created_at) VALUES(?,?,NOW())')->execute([$id,$name]);mobile_reply(['ok'=>true,'id'=>(int)db()->lastInsertId()],201);
        }
        $channel=desktop_positive($d['channel_id']??0);$q=db()->prepare('SELECT id,name FROM channels WHERE community_id=? AND id=?');$q->execute([$id,$channel]);$existing=$q->fetch();if(!$existing)mobile_fail('NOT_FOUND',404);
        if($route==='desktop-channel-rename'){
            $name=trim((string)($d['name']??''));if(!desktop_valid_channel($name))mobile_fail('INVALID_CHANNEL',422);
            $q=db()->prepare('SELECT 1 FROM channels WHERE community_id=? AND name=? AND id<>?');$q->execute([$id,$name,$channel]);if($q->fetchColumn())mobile_fail('NAME_TAKEN',409);
            db()->prepare('UPDATE channels SET name=? WHERE id=? AND community_id=?')->execute([$name,$channel,$id]);mobile_reply(['ok'=>true]);
        }
        if((string)($d['confirm_name']??'')!==(string)$existing['name'])mobile_fail('CONFIRM_NAME_REQUIRED',422);
        // Collect files before cascade delete; remove binaries only after successful transaction.
        $q=db()->prepare('SELECT a.stored_name FROM message_attachments a JOIN messages m ON m.id=a.message_id WHERE m.channel_id=?');$q->execute([$channel]);$files=$q->fetchAll(PDO::FETCH_COLUMN);
        db()->beginTransaction();try{db()->prepare('DELETE FROM channels WHERE id=? AND community_id=?')->execute([$channel,$id]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        foreach($files as $stored){if(preg_match('/^[a-f0-9]{32,48}\.[a-z0-9]{2,5}$/D',(string)$stored))@unlink(dirname(__DIR__).'/uploads/messages/'.$stored);}
        audit_event($uid,'channel.desktop_deleted',['channel_id'=>$channel]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-role-create'){
        desktop_feature('community-roles');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);
        $name=trim((string)($d['name']??''));$color=(string)($d['color']??'#C6A15B');$badge=(string)($d['badge_icon']??'');
        $allowed=['SEND_MESSAGES','MANAGE_MESSAGES','MANAGE_CHANNELS','MANAGE_MEMBERS','MANAGE_ROLES','CONNECT_VOICE','CREATE_TEMP_VOICE','MENTION_EVERYONE','MANAGE_COMMUNITY'];
        $permissions=$d['permissions']??[];if(!desktop_permission_set($permissions,$allowed)||!preg_match('/^[\pL\pN _-]{2,40}$/u',$name)||!preg_match('/^#[0-9a-fA-F]{6}$/',$color)||!in_array($badge,['','★','◆','✦','♛','⛨','⚡'],true))mobile_fail('INVALID_ROLE',422);
        db()->prepare('INSERT INTO community_roles(community_id,name,color,badge_icon,permissions,position,created_at) VALUES(?,?,?,?,?,(SELECT COALESCE(MAX(position),0)+1 FROM (SELECT position FROM community_roles WHERE community_id=?) r),NOW())')->execute([$id,$name,$color,$badge?:null,json_encode(array_values(array_unique($permissions))),$id]);
        audit_event($uid,'community.desktop_role_created',['community_id'=>$id]);mobile_reply(['ok'=>true,'id'=>(int)db()->lastInsertId()],201);
    }
    if($route==='desktop-role-permissions'){
        desktop_feature('community-roles');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);$role=desktop_positive($d['role_id']??0);
        $valid=['SEND_MESSAGES','MANAGE_MESSAGES','MANAGE_CHANNELS','MANAGE_MEMBERS','MANAGE_ROLES','CONNECT_VOICE','CREATE_TEMP_VOICE','MENTION_EVERYONE','MANAGE_COMMUNITY'];
        $perms=$d['permissions']??null;if(!desktop_permission_set($perms,$valid))mobile_fail('INVALID_PERMISSIONS',422);
        $q=db()->prepare('UPDATE community_roles SET permissions=? WHERE id=? AND community_id=?');$q->execute([json_encode(array_values(array_unique($perms))),$role,$id]);
        if($q->rowCount()===0){$exists=db()->prepare('SELECT 1 FROM community_roles WHERE id=? AND community_id=?');$exists->execute([$role,$id]);if(!$exists->fetchColumn())mobile_fail('NOT_FOUND',404);}
        audit_event($uid,'community.desktop_role_updated',['community_id'=>$id,'role_id'=>$role]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-role-assign'){
        desktop_feature('community-roles');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid);
        $target=desktop_positive($d['user_id']??0);$role=desktop_positive($d['role_id']??0);desktop_member($id,$target);
        $q=db()->prepare('SELECT 1 FROM community_roles WHERE community_id=? AND id=?');$q->execute([$id,$role]);if(!$q->fetchColumn())mobile_fail('ROLE_NOT_FOUND',404);
        db()->prepare('INSERT IGNORE INTO community_role_members(community_id,role_id,user_id) VALUES(?,?,?)')->execute([$id,$role,$target]);
        notify_user($target,'role_assigned',$uid,['community_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-member-ban'){
        desktop_feature('communities');$d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid,'MANAGE_MEMBERS');
        $target=desktop_positive($d['user_id']??0);$reason=mb_substr(trim((string)($d['reason']??'')),0,500);
        if(!$reason||$target===$uid)mobile_fail('INVALID_MEMBER',422);desktop_member($id,$target);
        $q=db()->prepare('SELECT user_id,member_role FROM community_members WHERE community_id=? AND user_id IN (?,?)');$q->execute([$id,$uid,$target]);$r=[];foreach($q->fetchAll() as $row)$r[(int)$row['user_id']]=$row['member_role'];
        if(($r[$target]??'')==='OWNER'||(($r[$target]??'')==='ADMIN'&&($r[$uid]??'')!=='OWNER'&&!in_array($actor['platform_role'],['OWNER','ADMIN'],true)))mobile_fail('FORBIDDEN',403);
        db()->beginTransaction();try{db()->prepare('INSERT INTO community_bans(community_id,user_id,moderator_id,reason,created_at) VALUES(?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE moderator_id=VALUES(moderator_id),reason=VALUES(reason),expires_at=NULL,created_at=NOW()')->execute([$id,$target,$uid,$reason]);db()->prepare('DELETE FROM community_role_members WHERE community_id=? AND user_id=?')->execute([$id,$target]);db()->prepare('DELETE FROM community_members WHERE community_id=? AND user_id=?')->execute([$id,$target]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        notify_user($target,'community_banned',$uid,['community_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-automod'){
        $id=desktop_positive(($_SERVER['REQUEST_METHOD']==='GET'?$_GET:[])['community_id']??0);if(($_SERVER['REQUEST_METHOD']??'')==='GET'){
            mobile_method('GET');desktop_manage($id,$uid,'MANAGE_MESSAGES');$q=db()->prepare('SELECT enabled,block_invites,block_external_links,slowmode_seconds FROM community_automod WHERE community_id=?');$q->execute([$id]);mobile_reply(['ok'=>true,'settings'=>$q->fetch(PDO::FETCH_ASSOC)?:[]]);
        }
        $d=desktop_input();$id=desktop_positive($d['community_id']??0);desktop_manage($id,$uid,'MANAGE_MESSAGES');
        $enabled=!empty($d['enabled'])?1:0;$invites=!empty($d['block_invites'])?1:0;$links=!empty($d['block_external_links'])?1:0;$slow=min(3600,max(0,(int)($d['slowmode_seconds']??0)));
        db()->beginTransaction();try{db()->prepare('INSERT INTO community_automod(community_id,enabled,block_invites,block_external_links,slowmode_seconds,updated_at) VALUES(?,?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE enabled=VALUES(enabled),block_invites=VALUES(block_invites),block_external_links=VALUES(block_external_links),slowmode_seconds=VALUES(slowmode_seconds),updated_at=NOW()')->execute([$id,$enabled,$invites,$links,$slow]);db()->prepare('UPDATE channels SET slowmode_seconds=? WHERE community_id=?')->execute([$slow,$id]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'community.desktop_automod_updated',['community_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    // Private messages and archives: require membership and authorship.
    if(in_array($route,['desktop-dm-edit','desktop-dm-delete'],true)){
        desktop_feature('direct-messages');$d=desktop_input();$cid=desktop_positive($d['conversation_id']??0);$mid=desktop_positive($d['message_id']??0);mobile_dm_access($cid,$uid);
        $q=db()->prepare('SELECT user_id FROM dm_messages WHERE conversation_id=? AND id=?');$q->execute([$cid,$mid]);if((int)$q->fetchColumn()!==$uid)mobile_fail('FORBIDDEN',403);
        if($route==='desktop-dm-edit'){$body=trim((string)($d['body']??''));if($body===''||mb_strlen($body)>10000)mobile_fail('INVALID_MESSAGE',422);if($blocked=circle_trust_preflight_error($body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);db()->prepare('UPDATE dm_messages SET body=?,edited_at=NOW() WHERE id=? AND conversation_id=? AND user_id=?')->execute([$body,$mid,$cid,$uid]);mobile_reply(['ok'=>true]);}
        $q=db()->prepare('SELECT stored_name FROM dm_attachments WHERE message_id=?');$q->execute([$mid]);$files=$q->fetchAll(PDO::FETCH_COLUMN);
        db()->beginTransaction();try{db()->prepare('UPDATE dm_messages SET reply_to_id=NULL WHERE conversation_id=? AND reply_to_id=?')->execute([$cid,$mid]);db()->prepare('DELETE FROM dm_messages WHERE id=? AND conversation_id=? AND user_id=?')->execute([$mid,$cid,$uid]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        foreach($files as $stored){if(preg_match('/^[a-f0-9]{32,48}\.[a-z0-9]{2,5}$/D',(string)$stored))@unlink(dirname(__DIR__).'/uploads/messages/'.$stored);}
        audit_event($uid,'dm.desktop_deleted',['message_id'=>$mid]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-dm-archive'){
        desktop_feature('direct-messages');$d=desktop_input();$cid=desktop_positive($d['conversation_id']??0);mobile_dm_access($cid,$uid);
        $archived=($d['archived']??null);if(!is_bool($archived))mobile_fail('INVALID_STATE',422);
        db()->prepare('INSERT INTO dm_conversation_preferences(conversation_id,user_id,is_archived,updated_at) VALUES(?,?,?,NOW()) ON DUPLICATE KEY UPDATE is_archived=VALUES(is_archived),updated_at=NOW()')->execute([$cid,$uid,$archived?1:0]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-dm-archives'){
        mobile_method('GET');desktop_feature('direct-messages');$q=db()->prepare('SELECT d.id,d.updated_at,u.id AS peer_id,u.username,p.display_name,p.avatar_path FROM dm_conversation_preferences pref JOIN dm_conversations d ON d.id=pref.conversation_id JOIN dm_members mine ON mine.conversation_id=d.id AND mine.user_id=? JOIN dm_members peer ON peer.conversation_id=d.id AND peer.user_id<>? JOIN users u ON u.id=peer.user_id LEFT JOIN user_profiles p ON p.user_id=u.id WHERE pref.user_id=? AND pref.is_archived=1 AND (SELECT COUNT(*) FROM dm_members m WHERE m.conversation_id=d.id)=2 ORDER BY d.updated_at DESC LIMIT 100');$q->execute([$uid,$uid,$uid]);$items=[];foreach($q->fetchAll() as $r)$items[]=['id'=>(int)$r['id'],'updated_at'=>$r['updated_at'],'peer'=>mobile_profile(['id'=>$r['peer_id'],'username'=>$r['username'],'display_name'=>$r['display_name'],'avatar_path'=>$r['avatar_path']])];mobile_reply(['ok'=>true,'items'=>$items]);
    }
    if(in_array($route,['desktop-channel-edit','desktop-channel-message-delete','desktop-channel-pin','desktop-channel-report'],true)){
        $d=desktop_input();$mid=desktop_positive($d['message_id']??0);$q=db()->prepare('SELECT m.user_id,m.channel_id,m.created_at,c.community_id FROM messages m JOIN channels c ON c.id=m.channel_id WHERE m.id=?');$q->execute([$mid]);$msg=$q->fetch(PDO::FETCH_ASSOC);if(!$msg)mobile_fail('NOT_FOUND',404);
        $cid=(int)$msg['community_id'];desktop_member($cid,$uid);mobile_channel_access((int)$msg['channel_id'],$uid);
        if($route==='desktop-channel-edit'){
            if((int)$msg['user_id']!==$uid||strtotime((string)$msg['created_at'])<time()-900)mobile_fail('FORBIDDEN',403);
            $body=trim((string)($d['body']??''));if($body===''||mb_strlen($body)>4000)mobile_fail('INVALID_MESSAGE',422);
            if($blocked=circle_trust_preflight_error($body))mobile_reply(['ok'=>false,'error'=>'MODERATION_BLOCKED','message'=>$blocked],422);
            db()->prepare('UPDATE messages SET body=?,edited_at=NOW() WHERE id=?')->execute([$body,$mid]);mobile_reply(['ok'=>true]);
        }
        if($route==='desktop-channel-pin'){desktop_manage($cid,$uid,'MANAGE_MESSAGES');db()->prepare('INSERT INTO message_pins(message_id,channel_id,pinned_by,pinned_at) VALUES(?,?,?,NOW()) ON DUPLICATE KEY UPDATE pinned_by=VALUES(pinned_by),pinned_at=NOW()')->execute([$mid,$msg['channel_id'],$uid]);mobile_reply(['ok'=>true]);}
        if($route==='desktop-channel-report'){
            desktop_feature('moderation');$reason=trim((string)($d['reason']??''));if((int)$msg['user_id']===$uid||mb_strlen($reason)<5||mb_strlen($reason)>500)mobile_fail('INVALID_REPORT',422);
            db()->prepare('INSERT INTO moderation_reports(reporter_id,target_user_id,message_id,reason,created_at,updated_at) VALUES(?,?,?,?,NOW(),NOW())')->execute([$uid,$msg['user_id'],$mid,$reason]);mobile_reply(['ok'=>true]);
        }
        if((int)$msg['user_id']!==$uid&&!has_community_permission($cid,$uid,'MANAGE_MESSAGES'))mobile_fail('FORBIDDEN',403);
        $q=db()->prepare('SELECT stored_name FROM message_attachments WHERE message_id=?');$q->execute([$mid]);$files=$q->fetchAll(PDO::FETCH_COLUMN);
        db()->prepare('DELETE FROM messages WHERE id=?')->execute([$mid]);foreach($files as $stored){if(preg_match('/^[a-f0-9]{32,48}\.[a-z0-9]{2,5}$/D',(string)$stored))@unlink(dirname(__DIR__).'/uploads/messages/'.$stored);}
        mobile_reply(['ok'=>true]);
    }
    // Group meetings use web room lifecycle, not an untrusted arbitrary LiveKit room.
    if($route==='desktop-meetings'){
        mobile_method('GET');$q=db()->prepare('SELECT v.id,v.title,v.created_at FROM voice_meetings v JOIN voice_meeting_members m ON m.meeting_id=v.id AND m.user_id=? WHERE v.last_activity_at>DATE_SUB(NOW(),INTERVAL 24 HOUR) ORDER BY v.id DESC LIMIT 40');$q->execute([$uid]);mobile_reply(['ok'=>true,'items'=>desktop_response_rows($q)]);
    }
    if($route==='desktop-meeting-create'){
        desktop_feature('temporary-voice-meetings');$d=desktop_input();$title=trim((string)($d['title']??'Встреча Circle'));$targets=$d['user_ids']??[];
        if(!is_array($targets)||mb_strlen($title)<2||mb_strlen($title)>100)mobile_fail('INVALID_MEETING',422);
        $targets=array_values(array_unique(array_filter(array_map('intval',$targets),static fn($id)=>$id>0&&$id!==$uid)));
        if(count($targets)<2||count($targets)>19)mobile_fail('FRIENDS_REQUIRED',422);
        foreach($targets as $target){$q=db()->prepare("SELECT 1 FROM friendships WHERE status='ACCEPTED' AND ((requester_id=? AND addressee_id=?) OR (requester_id=? AND addressee_id=?)) LIMIT 1");$q->execute([$uid,$target,$target,$uid]);if(!$q->fetchColumn())mobile_fail('FRIENDS_ONLY',403);}
        db()->beginTransaction();try{db()->prepare('INSERT INTO voice_meetings(title,created_by,created_at,last_activity_at) VALUES(?,?,NOW(),NOW())')->execute([$title,$uid]);$id=(int)db()->lastInsertId();$insert=db()->prepare('INSERT INTO voice_meeting_members(meeting_id,user_id,joined_at) VALUES(?,?,NOW())');foreach(array_merge([$uid],$targets) as $member)$insert->execute([$id,$member]);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        foreach($targets as $target){try{notify_user($target,'voice_meeting_invite',$uid,['meeting_id'=>$id]);}catch(Throwable $e){error_log('Circle desktop meeting notify: '.$e->getMessage());}}
        mobile_reply(['ok'=>true,'id'=>$id],201);
    }
    if(in_array($route,['desktop-meeting-token','desktop-meeting-heartbeat'],true)){
        $d=desktop_input();$id=desktop_positive($d['meeting_id']??0);$q=db()->prepare('SELECT 1 FROM voice_meeting_members m JOIN voice_meetings v ON v.id=m.meeting_id WHERE m.meeting_id=? AND m.user_id=? AND v.last_activity_at>=DATE_SUB(NOW(),INTERVAL 12 HOUR)');$q->execute([$id,$uid]);if(!$q->fetchColumn())mobile_fail('FORBIDDEN',403);
        db()->prepare('UPDATE voice_meetings SET last_activity_at=NOW() WHERE id=?')->execute([$id]);
        if($route==='desktop-meeting-heartbeat')mobile_reply(['ok'=>true]);
        desktop_feature('livekit');$url=trim(setting('livekit_url'));$parsed=parse_url($url);
        if(!is_array($parsed)||strtolower((string)($parsed['scheme']??''))!=='wss'||empty($parsed['host']))mobile_fail('LIVEKIT_NOT_CONFIGURED',503);
        $q=db()->prepare('SELECT title FROM voice_meetings WHERE id=?');$q->execute([$id]);$title=(string)$q->fetchColumn();
        try{$session=circle_call_session('meeting',$id,true);if(!$session||$session['status']!=='active')mobile_fail('CALL_UNAVAILABLE',409);$room=(string)$session['room_name'];$token=livekit_token($actor,$room,120);}catch(Throwable $e){mobile_fail('LIVEKIT_NOT_CONFIGURED',503);}
        mobile_reply(['ok'=>true,'url'=>$url,'token'=>$token,'room'=>$room,'title'=>$title,'expires_in'=>120]);
    }
    // Trust review remains admin-only and subject to the same audit trail as the web UI.
    if($route==='desktop-trust-panel'){
        mobile_method('GET');desktop_admin($actor);
        $q=db()->prepare('SELECT id,phrase,category,severity,enabled FROM circle_trust_rules ORDER BY id DESC LIMIT 200');$q->execute();$rules=desktop_response_rows($q);
        $q=db()->prepare("SELECT c.id,c.source_type,c.source_id,c.target_user_id,c.excerpt,c.status,c.created_at,u.username FROM circle_trust_cases c JOIN users u ON u.id=c.target_user_id WHERE c.status IN ('OPEN','REVIEWING') ORDER BY c.id DESC LIMIT 100");$q->execute();mobile_reply(['ok'=>true,'rules'=>$rules,'cases'=>desktop_response_rows($q)]);
    }
    if($route==='desktop-trust-rule-add'){
        desktop_admin($actor);$d=desktop_input();$phrase=trim((string)($d['phrase']??''));$category=trim((string)($d['category']??'LOCAL_POLICY'));$severity=(string)($d['severity']??'MEDIUM');
        if(mb_strlen($phrase)<2||mb_strlen($phrase)>160||!in_array($category,['PROHIBITED_MATERIAL','LOCAL_POLICY','THREAT','SPAM','HARASSMENT'],true)||!in_array($severity,['LOW','MEDIUM','HIGH'],true)||($severity==='HIGH'&&!in_array($category,['PROHIBITED_MATERIAL','THREAT'],true)))mobile_fail('INVALID_RULE',422);
        db()->prepare('INSERT INTO circle_trust_rules(phrase,category,severity,created_by) VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE category=VALUES(category),severity=VALUES(severity),enabled=1')->execute([$phrase,$category,$severity,$uid]);
        circle_trust_recheck_existing(db());audit_event($uid,'trust.desktop_rule_saved');mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-trust-rule-toggle'){
        desktop_admin($actor);$d=desktop_input();$id=desktop_positive($d['rule_id']??0);
        if($id<1)mobile_fail('INVALID_RULE',422);
        db()->prepare('UPDATE circle_trust_rules SET enabled=1-enabled WHERE id=?')->execute([$id]);
        circle_trust_recheck_existing(db());audit_event($uid,'trust.desktop_rule_toggled',['rule_id'=>$id]);mobile_reply(['ok'=>true]);
    }
    if($route==='desktop-trust-import'){
        desktop_admin($actor);mobile_method('POST');
        $category=(string)($_POST['category']??'LOCAL_POLICY');$severity=(string)($_POST['severity']??'MEDIUM');
        if(!in_array($category,['PROHIBITED_MATERIAL','LOCAL_POLICY','THREAT','SPAM','HARASSMENT'],true)||!in_array($severity,['LOW','MEDIUM','HIGH'],true)||($severity==='HIGH'&&!in_array($category,['PROHIBITED_MATERIAL','THREAT'],true)))mobile_fail('INVALID_RULE',422);
        try{$phrases=circle_trust_import_lines($_FILES['rules_document']??[]);}catch(Throwable $e){mobile_reply(['ok'=>false,'error'=>'INVALID_DOCUMENT','message'=>$e->getMessage()],422);}
        db()->beginTransaction();try{$q=db()->prepare('INSERT INTO circle_trust_rules(phrase,category,severity,created_by) VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE category=VALUES(category),severity=VALUES(severity),enabled=1');foreach($phrases as $p)$q->execute([$p,$category,$severity,$uid]);circle_trust_recheck_existing(db());db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'trust.desktop_rules_imported',['count'=>count($phrases)]);mobile_reply(['ok'=>true,'count'=>count($phrases)]);
    }
    if($route==='desktop-trust-review'){
        desktop_admin($actor);$d=desktop_input();$id=desktop_positive($d['case_id']??0);$status=(string)($d['status']??'');$note=trim((string)($d['note']??''));
        if(!in_array($status,['REVIEWING','DISMISSED','CONFIRMED'],true)||($status!=='REVIEWING'&&mb_strlen($note)<3)||mb_strlen($note)>500)mobile_fail('INVALID_DECISION',422);
        db()->beginTransaction();try{$q=db()->prepare('SELECT status FROM circle_trust_cases WHERE id=? FOR UPDATE');$q->execute([$id]);$old=$q->fetchColumn();if(!in_array($old,['OPEN','REVIEWING'],true)){db()->rollBack();mobile_fail('CASE_CLOSED',409);}db()->prepare('UPDATE circle_trust_cases SET status=?,moderator_id=?,resolution_note=?,reviewed_at=NOW() WHERE id=?')->execute([$status,$uid,$note,$id]);db()->prepare('INSERT INTO circle_moderation_decisions(case_kind,case_id,action,actor_id,note,sanction) VALUES(?,?,?,?,?,?)')->execute(['TRUST',$id,$status,$uid,$note,'NONE']);db()->commit();}catch(Throwable $e){if(db()->inTransaction())db()->rollBack();throw $e;}
        audit_event($uid,'trust.desktop_case_reviewed',['case_id'=>$id,'status'=>$status]);mobile_reply(['ok'=>true]);
    }
    mobile_fail('NOT_FOUND',404);
}
