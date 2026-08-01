import { createClient } from "npm:@supabase/supabase-js@2.57.4";
// @ts-ignore npm package uses CommonJS exports supported by the Edge runtime.
import webpush from "npm:web-push@3.6.7";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const cronSecret = Deno.env.get("PUSH_CRON_SECRET")!;
const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY")!;
const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY")!;
const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "https://kubbmesterskap.vercel.app/";

webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
const db = createClient(url, serviceKey, { auth:{ persistSession:false, autoRefreshToken:false } });

Deno.serve(async request => {
  if(!cronSecret || request.headers.get("x-kubb-cron-secret") !== cronSecret){
    return Response.json({ error:"unauthorized" }, { status:401 });
  }

  const { data:tournament, error:tournamentError } = await db
    .from("kubb_tournament").select("match_seconds").eq("id", 1).single();
  if(tournamentError) return Response.json({ error:tournamentError.message }, { status:500 });

  const { data:matches, error:matchError } = await db
    .from("kubb_matches")
    .select("id,court,team_a,team_b,started_at,pause_accum,extra_seconds,status")
    .eq("status", "live").not("started_at", "is", null);
  if(matchError) return Response.json({ error:matchError.message }, { status:500 });

  const now = Date.now();
  const expired = (matches || []).map(match => ({
    ...match,
    expiresAt:new Date(Date.parse(match.started_at) +
      ((tournament.match_seconds || 0) + (match.pause_accum || 0) + (match.extra_seconds || 0)) * 1000)
  })).filter(match => match.expiresAt.getTime() <= now);
  if(!expired.length) return Response.json({ ok:true, expired:0, sent:0 });

  const [{ data:subscriptions, error:subscriptionError }, { data:teams, error:teamError }] = await Promise.all([
    db.from("kubb_push_subscriptions").select("id,endpoint,p256dh,auth,team_id,is_admin"),
    db.from("kubb_teams").select("id,name")
  ]);
  if(subscriptionError || teamError){
    return Response.json({ error:(subscriptionError || teamError)?.message }, { status:500 });
  }
  const names = new Map((teams || []).map(team => [team.id, team.name]));
  let sent = 0;

  for(const match of expired){
    const targets = (subscriptions || []).filter(subscription =>
      subscription.is_admin || subscription.team_id === match.team_a || subscription.team_id === match.team_b
    );
    for(const subscription of targets){
      const delivery = {
        match_id:match.id,
        subscription_id:subscription.id,
        expires_at:match.expiresAt.toISOString()
      };
      const { error:claimError } = await db.from("kubb_push_deliveries").insert(delivery);
      if(claimError?.code === "23505") continue;
      if(claimError) continue;

      const court = match.court ? ` på bane ${match.court}` : "";
      const payload = JSON.stringify({
        title:`Tiden er ute${court}`,
        body:`${names.get(match.team_a) || "Lag A"} mot ${names.get(match.team_b) || "Lag B"}. Kampen er fortsatt åpen for resultat.`,
        tag:`kubb-expiry-${match.id}`,
        url:"/?open=courts"
      });
      try {
        await webpush.sendNotification({
          endpoint:subscription.endpoint,
          keys:{ p256dh:subscription.p256dh, auth:subscription.auth }
        }, payload, { TTL:300, urgency:"high" });
        sent++;
      } catch(error){
        const failure = error as { statusCode?:number; status?:number };
        const status = Number(failure.statusCode || failure.status || 0);
        if(status === 404 || status === 410){
          await db.from("kubb_push_subscriptions").delete().eq("id", subscription.id);
        } else {
          await db.from("kubb_push_deliveries")
            .delete()
            .eq("match_id", match.id)
            .eq("subscription_id", subscription.id)
            .eq("expires_at", match.expiresAt.toISOString());
        }
      }
    }
  }

  return Response.json({ ok:true, expired:expired.length, sent });
});
