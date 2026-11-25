import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

AiDraft businessDecision() => AiDraft.fromJson({
  'reply':'Order repair needs an authorized colleague.',
  'decision':'human_review_required','human_review_required':true,
  'risk_triggers':['order_service_handoff'],'reason':'Requires order authority',
  'confidence':1,'risk_level':'medium','used_record_ids':[],'actions':[],
  'attachments':[],'auto_send_allowed':false,'model':'fixture'
},mediaBaseUrl:Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  const customer='buyer';
  const source='source_agent';
  setUp(() async {
    root=await Directory.systemTemp.createTemp('v30_business_');
    db=CaptureDatabase(storageRoot:root);
  });
  tearDown(() async {await db.close();await root.delete(recursive:true);});
  Future<void> capture(String id) async {
    await db.saveCapture(CapturedConversation(stableKey:customer,customerName:customer,
      customerExternalId:customer,capturedAt:DateTime.now(),messages:[
        CapturedMessage(stableId:id,direction:'incoming',body:'Please arrange repair for order $id',axPath:'fixture')
      ]));
  }
  Future<(HumanReviewTicket,ChatTransferLog)> pending() async {
    await capture('order1');
    final pending=(await db.conversations()).single;
    await db.saveDraft(pending.id,businessDecision(),expectedMessageId:'order1',deliverable:false);
    final ticket=await db.createHumanReviewTicket(userId:customer,customerRequest:'repair order1',
      reason:'Requires order authority',requestMessageId:'order1');
    final log=(await db.reserveChatTransferLog(ticket:ticket))!;
    await db.updateChatTransferLog(id:log.id,status:'pending',sourceAccount:source);
    await db.markTicketHandoffPending(ticket.id);
    return(ticket,log);
  }
  Future<HumanReviewTicket> newRequest() async {
    await capture('order2');
    return db.createHumanReviewTicket(userId:customer,customerRequest:'repair order1 and order2',
      reason:'Requires order authority',requestMessageId:'order2');
  }
  Future<Map<String,Object?>> row(int id) async =>
    (await (await db.database).query('chat_transfer_logs',where:'id=?',whereArgs:[id])).single;
  Map<String,Object?> proof({String owner=source,String who=customer}) => {
    'ready':true,'ownershipConfirmed':true,'ownershipProof':'current_enabled_empty_reception_ax','currentCustomer':who,
    'activeCustomerId':who,'sourceAccount':owner,'observedAtMs':DateTime.now().millisecondsSinceEpoch};

  test('legacy explicitly unclicked failure recovers once and can serve the order',() async {
    final(ticket,log)=await pending();
    await (await db.database).update('chat_transfer_logs',{'status':'failed','phase':'legacy',
      'owner_pid':null,'error':'PlatformException(transfer_budget_exceeded, no transfer was clicked., {transferClicked: false})'},
      where:'id=?',whereArgs:[log.id]);
    await db.recoverChatTransferAttempts(activeCustomers:{});
    expect((await db.duePreclickHandoffs()).single.id,ticket.id);
    expect((await row(log.id))['phase'],'retryable_preclick');
    final due=(await row(log.id))['preclick_retry_at_ms'];
    await db.recoverChatTransferAttempts(activeCustomers:{});
    expect((await row(log.id))['preclick_retry_at_ms'],due);
    expect(await db.reserveChatTransferLog(ticket:ticket),isNotNull);
    expect((await row(log.id))['preclick_retry_count'],1);
    expect(await db.answeredMessageId(customer),isNull,reason:'Recovery is not a business answer');
    await db.updateChatTransferLog(id:log.id,status:'transferred',targetAccount:'authorized_agent',transferClicked:true);
    await db.markTicketContacted(ticket.id,assignedTo:'authorized_agent');
    expect(await db.hasUndeliveredDraft(customer),isFalse);
    expect(await db.answeredMessageId(customer),'order1');
  });
  test('legacy failed status without positive no-click proof does not gain a retry',() async {
    final(_,log)=await pending();
    await (await db.database).update('chat_transfer_logs',{'status':'failed','phase':'legacy','error':'timeout'},where:'id=?',whereArgs:[log.id]);
    await db.recoverChatTransferAttempts(activeCustomers:{});
    expect(await db.duePreclickHandoffs(),isEmpty);
    expect((await row(log.id))['preclick_retry_at_ms'],0);
  });
  test('classified modern failure retains an intentional zero retry',() async {
    final(_,log)=await pending();
    await db.updateChatTransferLog(id:log.id,status:'failed',phase:'retryable_preclick',error:'transfer_budget_exceeded transferClicked: false');
    await db.recoverChatTransferAttempts(activeCustomers:{});
    expect(await db.duePreclickHandoffs(),isEmpty);
  });
  test('unknown old transfer gives explicit business block and keeps later order details',() async {
    final(ticket,log)=await pending();
    await db.updateChatTransferLog(id:log.id,status:'unconfirmed');
    await newRequest();
    expect(await db.reserveChatTransferLog(ticket:ticket),isNull);
    final status=(await db.handoffServiceStatus(customer))!;
    expect(status['state'],'new_request_ownership_required');
    expect(status['handoffCompleted'],isFalse);
    expect(status['businessResponseSent'],isFalse);
    expect(status['caseResolved'],isNull);
    await db.markTicketHandoffBlocked(ticket.id,status['state']! as String);
    expect(await db.isHandoffPending(customer),isTrue);
    await capture('order3');
    final current=(await db.conversations()).single;
    expect(await db.beginGeneration(customer:customer,pendingId:current.id,batchEndMessageId:'order3'),isNull);
    expect((await (await db.database).query('human_review_tickets')).single['customer_request'],contains('order3'));
    expect(await db.answeredMessageId(customer),isNull);
    expect((await db.blockedHandoffServices()).single['ticketId'],ticket.id);
  });
  test('new request and fresh matching AX source create an independent task, retaining old unknown',() async {
    final(old,log)=await pending();
    await db.updateChatTransferLog(id:log.id,status:'unconfirmed');
    final fresh=await newRequest();
    final next=await db.startNewHandoffAfterReceptionProof(ticketId:fresh.id,proof:proof(),sourceAccount:source);
    expect(next,isNotNull);expect(next!.id,isNot(old.id));
    final log2=await db.reserveChatTransferLog(ticket:next);
    expect(log2,isNotNull);expect(log2!.id,isNot(log.id));
    expect((await row(log.id))['status'],'unconfirmed');
    expect((await (await db.database).query('human_review_tickets',where:'id=?',whereArgs:[old.id])).single['status'],'superseded_unconfirmed');
    expect(await db.answeredMessageId(customer),isNull);
    expect(next.customerRequest,contains('order1'));
  });
  test('same request cannot retry an unknown transfer even with a fresh reception proof',() async {
    final(ticket,log)=await pending();await db.updateChatTransferLog(id:log.id,status:'unconfirmed');
    expect(await db.startNewHandoffAfterReceptionProof(ticketId:ticket.id,proof:proof(),sourceAccount:source),isNull);
    expect((await (await db.database).query('human_review_tickets')),hasLength(1));
  });
  for(final invalid in ['wrong_customer','changed_source','missing_proof','stale','not_ready','future']) {
    test('$invalid evidence cannot authorize a new physical transfer',() async {
      final(ticket,log)=await pending();await db.updateChatTransferLog(id:log.id,status:'unconfirmed');await newRequest();
      final p=proof();
      if(invalid=='wrong_customer')p['currentCustomer']='other';
      if(invalid=='changed_source')p['sourceAccount']='other_agent';
      if(invalid=='missing_proof')p.remove('ownershipProof');
      if(invalid=='stale')p['observedAtMs']=DateTime.now().subtract(const Duration(minutes:1)).millisecondsSinceEpoch;
      if(invalid=='future')p['observedAtMs']=DateTime.now().add(const Duration(minutes:1)).millisecondsSinceEpoch;
      if(invalid=='not_ready')p['ready']=false;
      expect(await db.startNewHandoffAfterReceptionProof(ticketId:ticket.id,proof:p,sourceAccount:source),isNull);
      expect((await row(log.id))['status'],'unconfirmed');
    });
  }
  test('an operator takeover cannot be overwritten by block or reception recovery',() async {
    final(ticket,log)=await pending();await db.updateChatTransferLog(id:log.id,status:'unconfirmed');await newRequest();
    await db.markTicketContacting(ticket.id);
    await db.markTicketHandoffBlocked(ticket.id,'previous_transfer_unknown');
    expect(await db.startNewHandoffAfterReceptionProof(ticketId:ticket.id,proof:proof(),sourceAccount:source),isNull);
    expect(await db.isHumanContacting(customer),isTrue);
    expect(await db.blockedHandoffServices(),isEmpty);
  });
}
