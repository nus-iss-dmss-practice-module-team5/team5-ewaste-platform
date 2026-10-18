#!/usr/bin/env python3
"""Idempotently append Sprint 4 groups to EWCSB-194, preserving existing groups."""

from pathlib import Path
import xml.etree.ElementTree as E

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "artifacts/jmeter/EWaste_API_Test_Plan.jmx"
COMMON = """import groovy.json.JsonSlurper
import groovy.json.JsonOutput
import java.time.Instant
import java.util.concurrent.*
def S = props.get('s4.state')
def F = vars.getObject('s4.fixture')
def check = { ok, msg -> if (!ok) throw new IllegalStateException(msg) }
def json = { x -> JsonOutput.toJson(x) }
def parse = { x -> new JsonSlurper().parseText(x) }
def key = { -> 's4-' + UUID.randomUUID().toString() }
def save = { row -> synchronized(S.records) { S.records.add(row); new File(S.output,'requests.jsonl').append(json(row)+'\\n','UTF-8') } }
def metricCheck = { actual, f ->
 check(actual.data_quality == f.golden.quality, 'Wrong data quality')
 f.golden.metrics.each { k,v -> check(actual[k] == v, 'Metric mismatch: '+k) }
}
"""


def prop(n, k, v, kind="stringProp"):
    E.SubElement(n, kind, name=k).text = (
        str(v).lower() if isinstance(v, bool) else str(v)
    )


def node(tree, tag, name, gui=None, **attrs):
    n = E.SubElement(
        tree,
        tag,
        guiclass=gui or tag + "Gui",
        testclass=tag,
        testname=name,
        enabled="true",
        **attrs
    )
    h = E.SubElement(tree, "hashTree")
    return n, h


def script(tree, name, body, tag="JSR223Sampler", wrap=True):
    n, h = node(tree, tag, name, "TestBeanGUI")
    for k, v in [
        ("scriptLanguage", "groovy"),
        ("parameters", ""),
        ("filename", ""),
        ("cacheKey", "true"),
    ]:
        prop(n, k, v)
    if wrap:
        body = (
            COMMON
            + "try {\n"
            + body
            + """\nSampleResult.setSuccessful(true); SampleResult.setResponseCode('200'); SampleResult.setResponseMessage('PASS');
} catch (Exception e) {
 if (S != null) S.failed=true
 SampleResult.setSuccessful(false); SampleResult.setResponseCode('CHECK_FAILED');
 SampleResult.setResponseMessage(e instanceof IllegalStateException ? 'S4 check failed: '+e.message : 'S4 fixture/state check failed'); SampleResult.setStopTest(true)
}"""
        )
    prop(n, "script", body)
    return n, h


def race_binding_script(kind):
    """Validate shared setup before binding; expose controlled diagnostics only."""
    return (
        COMMON
        + """def problem='Unable to bind the __KIND__ race fixture'
def require={ok,msg->problem=msg;if(!ok)throw new IllegalStateException()}
try {
 require(S instanceof Map,'S4 setup state is missing. Enable S4 12 and run it together with S4 __GROUP__ in the same test run; do not start the race group alone.')
 require(S.failed != true,'An earlier S4 step failed. Fix that failure and restart from S4 12.')
 require(S.profile in ['all','__KIND__'],'S4 setup did not include this race. Use s4_profile=all or __KIND__ and restart from S4 12.')
 require(S.tokens instanceof Map && !S.tokens.isEmpty(),'S4 login tokens are missing. Complete S4 12 in the same run.')
 def role=__ROLE__
 require(S.tokens[role] instanceof Map && S.tokens[role].access,'The '+role+' login token is missing. Complete S4 12 in the same run.')
 require(S.tokens.values().every{it instanceof Map && it.expiry instanceof Number},'S4 token expiry is missing or invalid. Restart from S4 12 to log in again.')
 require(S.tokens.values().every{it.expiry > Instant.now().epochSecond+120},'S4 tokens have less than 120 seconds remaining. Restart from S4 12 and run the selected groups consecutively.')
 require(S.fixtures instanceof List,'S4 fixture pool is missing. Complete S4 12 in the same run.')
 def f=S.fixtures.find{it.scenario=='__KIND__-race'}
 require(f instanceof Map && f.id && f.version instanceof Number,'The __KIND__ race batch is missing or incomplete. Complete S4 12 with s4_profile=all or __KIND__.')
 __FIXTURE_CHECK__
 require(S.races instanceof Map,'S4 race state is missing. Restart from S4 12.')
 problem='Unable to bind the __KIND__ race fixture. Restart from S4 12.'
 vars.putObject('s4.fixture',f)
 vars.put('s4.race_role',role)
 vars.put('s4.assignment',f.assignment ?: '')
 S.races.computeIfAbsent('__KIND__') {new ConcurrentLinkedQueue()}
 SampleResult.setSuccessful(true);SampleResult.setResponseCode('200');SampleResult.setResponseMessage('PASS')
} catch(Exception|AssertionError e) {
 if(S instanceof Map)S.failed=true
 SampleResult.setSuccessful(false);SampleResult.setResponseCode('CHECK_FAILED')
 SampleResult.setResponseMessage(problem);SampleResult.setResponseData(problem,'UTF-8')
 log.warn('AUX_BIND___UPPER__: '+problem);SampleResult.setStopTest(true)
}
""".replace("__KIND__", kind)
        .replace("__UPPER__", kind.upper())
        .replace("__GROUP__", "13" if kind == "claim" else "15")
        .replace(
            "__ROLE__",
            (
                "ctx.threadNum%2==0?'recycler':'recycler2'"
                if kind == "claim"
                else "'collector'"
            ),
        )
        .replace(
            "__FIXTURE_CHECK__",
            (
                "require(f.epoch != null,'The claim epoch is missing. Complete S4 12 in the same run.')"
                if kind == "claim"
                else "require(f.assignment && f.handoff instanceof Map && !f.handoff.isEmpty(),'The handoff assignment or frozen payload is missing. Complete S4 12 through AUX_FREEZE_HANDOFF before running S4 15.')"
            ),
        )
    )


def cond(tree, expr):
    n, h = node(tree, "IfController", "S4 condition", "IfControllerPanel")
    prop(n, "IfController.condition", expr)
    prop(n, "IfController.evaluateAll", False, "boolProp")
    prop(n, "IfController.useExpression", True, "boolProp")
    return h


def loop(tree, name, count):
    n, h = node(tree, "LoopController", name, "LoopControlPanel")
    prop(n, "LoopController.continue_forever", False, "boolProp")
    prop(n, "LoopController.loops", count)
    return h


def group(tree, name, threads="1", profiles="all", tag="ThreadGroup"):
    n, h = node(
        tree,
        tag,
        name,
        (
            "ThreadGroupGui"
            if tag == "ThreadGroup"
            else (
                "SetupThreadGroupGui"
                if tag == "SetupThreadGroup"
                else "PostThreadGroupGui"
            )
        ),
    )
    prop(n, "ThreadGroup.on_sample_error", "stoptest")
    lc = E.SubElement(
        n,
        "elementProp",
        name="ThreadGroup.main_controller",
        elementType="LoopController",
        guiclass="LoopControlPanel",
        testclass="LoopController",
        testname="Loop Controller",
        enabled="true",
    )
    prop(lc, "LoopController.continue_forever", False, "boolProp")
    prop(lc, "LoopController.loops", 1)
    prop(n, "ThreadGroup.num_threads", threads)
    prop(n, "ThreadGroup.ramp_time", "${s4_ramp_seconds}")
    prop(n, "ThreadGroup.scheduler", False, "boolProp")
    prop(n, "ThreadGroup.same_user_on_next_iteration", True, "boolProp")
    return cond(
        h,
        "${__groovy(vars.get('run_s4') == 'true' && vars.get('s4_profile') ==~ /"
        + profiles
        + "/)}",
    )


def http(
    tree,
    label,
    method,
    path,
    role,
    body=None,
    expected="200",
    verify="",
    pre="",
    sync=None,
    neg=False,
    record=True,
):
    n, h = node(tree, "HTTPSamplerProxy", label, "HttpTestSampleGui")
    a = E.SubElement(
        n,
        "elementProp",
        name="HTTPsampler.Arguments",
        elementType="Arguments",
        guiclass="HTTPArgumentsPanel",
        testclass="Arguments",
        testname="Body",
    )
    col = E.SubElement(a, "collectionProp", name="Arguments.arguments")
    if body is not None:
        arg = E.SubElement(col, "elementProp", name="", elementType="HTTPArgument")
        prop(arg, "HTTPArgument.always_encode", False, "boolProp")
        prop(arg, "Argument.value", "${s4.body}")
        prop(arg, "Argument.metadata", "=")
    for k, v in [
        ("domain", ""),
        ("port", ""),
        ("protocol", ""),
        ("contentEncoding", "UTF-8"),
        ("path", "${s4.host}" + path),
        ("method", method),
        ("implementation", "HttpClient4"),
        ("connect_timeout", "${s4_connect_ms}"),
        ("response_timeout", "${s4_response_ms}"),
    ]:
        prop(n, "HTTPSampler." + k, v)
    for k, v in [
        ("follow_redirects", False),
        ("auto_redirects", False),
        ("use_keepalive", True),
        ("DO_MULTIPART_POST", False),
        ("postBodyRaw", True),
    ]:
        prop(n, "HTTPSampler." + k, v, "boolProp")
    headers, hh = node(h, "HeaderManager", "S4 request headers", "HeaderPanel")
    col = E.SubElement(headers, "collectionProp", name="HeaderManager.headers")
    pairs = [("Accept", "application/json"), ("X-Correlation-ID", "${correlation_id}")]
    if role:
        pairs.append(("Authorization", "Bearer ${s4.token}"))
    if body is not None:
        pairs.append(("Content-Type", "application/json"))
    if method == "POST" and "auth/" not in path:
        pairs.extend(
            [("Idempotency-Key", "${s4.key}"), ("If-Match-Version", "${s4.version}")]
        )
    for k, v in pairs:
        a = E.SubElement(col, "elementProp", name="", elementType="Header")
        prop(a, "Header.name", k)
        prop(a, "Header.value", v)
    pp = (
        COMMON
        + "check(S != null && !S.failed, 'Setup or previous request failed')\nvars.put('s4.host',S.host);vars.put('run_id',S.run);vars.put('batch_id',F?.id ?: '')\nvars.put('correlation_id',key());vars.put('s4.key',key());vars.put('s4.version',(F?.version ?: 1).toString())\n"
    )
    if role:
        pp += (
            "vars.put('s4.role',"
            + role
            + ");vars.put('s4.token',S.tokens[vars.get('s4.role')].access)\n"
        )
    pp += pre + "\n"
    if body is not None:
        pp += "vars.put('s4.body',json(" + body + "))\n"
    if sync:
        pp += (
            "S.arrivals.computeIfAbsent('"
            + label
            + "') { new java.util.concurrent.atomic.AtomicInteger() }.incrementAndGet()\n"
        )
    script(
        h,
        "S4 prepare request",
        COMMON
        + "try {\n"
        + pp[len(COMMON) :]
        + "\n} catch (Exception e) { if(S != null) S.failed=true; ctx.getThread().stop(); throw new IllegalStateException('S4 request preparation failed; check configuration and fixture state') }",
        "JSR223PreProcessor",
        False,
    )
    if sync:
        tim, th = node(h, "SyncTimer", "S4 synchronise " + label, "TestBeanGUI")
        prop(tim, "groupSize", sync)
        prop(tim, "timeoutInMs", "${s4_barrier_ms}")
    assertion = (
        COMMON
        + """def j = null
try {
 check(prev.responseCode in """
        + str(expected.split("|"))
        + """, 'Unexpected HTTP '+prev.responseCode)
 j=parse(prev.responseDataAsString)
 check(j instanceof Map, 'Expected JSON object')
 check(prev.responseHeaders.toLowerCase().contains('x-correlation-id:'), 'Missing correlation header')
"""
    )
    if sync:
        assertion += (
            " check(S.arrivals['"
            + label
            + "'].get() == ("
            + sync.replace("${", "vars.get('").replace("}", "').toInteger()")
            + "), 'Barrier timed out before all contenders arrived')\n"
        )
    assertion += verify + """
 prev.setSuccessful(true)
} catch (Exception e) {
 S.failed=true; AssertionResult.setFailure(true); AssertionResult.setFailureMessage(e instanceof IllegalStateException ? e.message : 'Response decoding or contract check failed'); prev.setSuccessful(false); prev.setStopTest(true)
} finally {
"""
    if record:
        assertion += (
            " save([label:prev.sampleLabel,run_id:S.run,scenario:F?.scenario,batch_id:F?.id,assignment_id:F?.assignment,case_name:F?.golden?.name,role:vars.get('s4.role'),organisation:S.tokens[vars.get('s4.role')]?.org,key:vars.get('s4.key'),expected_version:vars.get('s4.version'),correlation_id:vars.get('correlation_id'),source_event_id:j?.event_id ?: j?.data?.event_id,start_ms:prev.startTime,end_ms:prev.endTime,elapsed:prev.time,http:prev.responseCode,success:prev.successful,expected_negative:"
            + str(neg).lower()
            + "])\n"
        )
    assertion += "}"
    script(
        h,
        "S4 assert contract and retain identifiers",
        assertion,
        "JSR223Assertion",
        False,
    )
    return n, h


def poll(tree, kind):
    script(
        tree,
        "AUX_START_" + kind,
        "vars.put('s4.done','false');vars.put('s4.deadline',(System.currentTimeMillis()+vars.get('s4_poll_timeout_seconds').toLong()*1000L).toString())",
    )
    n, h = node(tree, "WhileController", "AUX bounded " + kind, "WhileControllerGui")
    prop(
        n,
        "WhileController.condition",
        "${__groovy(vars.get('s4.done') != 'true' && System.currentTimeMillis() < vars.get('s4.deadline').toLong())}",
    )
    if kind == "MATCH":
        http(
            h,
            "AUX_POLL_MATCH",
            "GET",
            "/api/v1/opportunities/${batch_id}",
            "'recycler'",
            expected="200|404",
            verify="""if(prev.responseCode=='404') check(j.code=='NOT_FOUND','Unexpected matching error')
else { check(j.data.batch_id==F.id && j.data.status=='MATCHED' && j.data.version instanceof Number && j.data.claim_epoch, 'Invalid matching result');F.version=j.data.version;F.epoch=j.data.claim_epoch;vars.put('s4.done','true') }""",
        )
    else:
        http(
            h,
            "AUX_POLL_COMPLETION",
            "GET",
            "/api/v1/processing/batches/${batch_id}",
            "'recycler'",
            verify="""check(j.data.batch_id==F.id && j.data.status in ['RECYCLED','COMPLETED'], 'Invalid completion state')
if(j.data.status=='COMPLETED') {check(j.data.version==F.version+1,'Completion version mismatch');check(j.data.actual_weight_kg==F.golden.receipt.actual_weight_kg,'Received weight changed');metricCheck(j.data,F);check(j.data.anomaly_codes.sort(false)==F.golden.flags.sort(false),'Wrong persisted anomaly flags');F.completed_version=j.data.version;F.completed=true;vars.put('s4.done','true')}""",
        )
    # Timer belongs only to poll request, outside all scored samples.
    child = h[-1]
    t, th = node(child, "ConstantTimer", "S4 polling interval", "ConstantTimerGui")
    prop(t, "ConstantTimer.delay", "${s4_poll_interval_ms}")
    script(
        tree,
        "AUX_ASSERT_" + kind,
        "check(vars.get('s4.done')=='true', '"
        + kind
        + " timeout; check worker, eligibility, capacity and persisted event evidence')",
    )


def read_batch(tree, status):
    http(
        tree,
        "AUX_VERIFY_" + status,
        "GET",
        "/api/v1/batches/${batch_id}",
        "'donor'",
        verify="check(j.data.batch_id==F.id && j.data.status=='"
        + status
        + "' && j.data.version==F.version,'Wrong persisted batch identity/state/version')",
    )


def claim(tree, label="SETUP_CLAIM", sync=None):
    http(
        tree,
        label,
        "POST",
        "/api/v1/batches/${batch_id}/claim",
        "'recycler'",
        "[expected_version:F.version,claim_epoch:F.epoch]",
        sync=sync,
        verify="""check(j.data.batch_id==F.id && j.data.status=='APPROVED' && j.data.version==F.version+1 && j.data.claim_id && j.data.reservation_id && j.data.event_id,'Invalid claim acknowledgement');F.claim=j.data.claim_id;F.version=j.data.version""",
    )


def assign(tree, label="SETUP_ASSIGN", sync=None):
    http(
        tree,
        "AUX_COLLECTOR_SCOPE",
        "GET",
        "/api/v1/batches/${batch_id}",
        "'collector'",
        verify="check(j.data.batch_id==F.id && j.data.status=='APPROVED' && j.data.version==F.version && j.data.collector_scope_id,'Missing valid collector scope');F.scope=j.data.collector_scope_id",
    )
    http(
        tree,
        label,
        "POST",
        "/api/v1/batches/${batch_id}/assignments",
        "'collector'",
        "[expected_version:F.version,claim_epoch:F.epoch,collector_scope_id:F.scope]",
        expected="201",
        sync=sync,
        verify="check(j.data.batch_id==F.id && j.data.assignment_status=='ACCEPTED' && j.data.assignment_id && j.event_id,'Invalid assignment');F.assignment=j.data.assignment_id;F.version=F.version+1",
    )
    read_batch(tree, "ASSIGNED")
    http(
        tree,
        "AUX_READ_ASSIGNMENT",
        "GET",
        "/api/v1/assignments/${s4.assignment}",
        "'collector'",
        pre="vars.put('s4.assignment',F.assignment)",
        verify="check(j.data.assignment_id==F.assignment && j.data.batch_id==F.id && j.data.assignment_status=='ACCEPTED' && j.data.created_at,'Invalid assignment read');Instant.parse(j.data.created_at);F.assigned_at=j.data.created_at",
    )
    script(
        tree,
        "AUX_FREEZE_HANDOFF",
        "F.handoff=[pickup_occurred_at:F.assigned_at,donor_representative_name:'Synthetic JMeter',actual_item_count:5,verification_hash:java.security.MessageDigest.getInstance('SHA-256').digest((S.run+F.id).getBytes('UTF-8')).encodeHex().toString(),notes:'S4LD:'+S.run]",
    )


def handoff(tree, label="SETUP_HANDOFF", sync=None):
    http(
        tree,
        label,
        "POST",
        "/api/v1/assignments/${s4.assignment}/handoff",
        "'collector'",
        "F.handoff",
        sync=sync,
        pre="vars.put('s4.assignment',F.assignment)",
        verify="""check(j.data.batch_id==F.id && j.data.assignment_id==F.assignment && j.data.assignment_status=='COMPLETED' && j.event_id,'Invalid handoff');F.handoff_replay=[key:vars.get('s4.key'),version:F.version,data:j.data,event:j.event_id];F.version=F.version+1""",
    )
    read_batch(tree, "COLLECTED")


def receipt(tree, label="SETUP_RECEIPT", sync=None, negative=False):
    if negative:
        for nm, role, body, ver, code, status in [
            (
                "FORBIDDEN",
                "'donor'",
                "F.golden.receipt",
                "F.version",
                "FORBIDDEN",
                "403",
            ),
            (
                "STALE",
                "'recycler'",
                "F.golden.receipt",
                "F.version-1",
                "STALE_VERSION",
                "409",
            ),
            (
                "INVALID",
                "'recycler'",
                "F.golden.receipt + [actual_item_count:0]",
                "F.version",
                "VALIDATION_ERROR",
                "422",
            ),
        ]:
            http(
                tree,
                "NEG_RECEIPT_" + nm,
                "POST",
                "/api/v1/batches/${batch_id}/receipt",
                role,
                body,
                expected=status,
                pre="vars.put('s4.version',(" + ver + ").toString())",
                verify="check(j.code=='" + code + "','Wrong rejection code')",
                neg=True,
            )
        read_batch(tree, "COLLECTED")
    http(
        tree,
        label,
        "POST",
        "/api/v1/batches/${batch_id}/receipt",
        "'recycler'",
        "F.golden.receipt",
        sync=sync,
        verify="""check(j.data.batch_id==F.id && j.data.status=='VERIFIED' && j.data.version==F.version+1 && j.data.receipt_id && j.event_id,'Invalid receipt');F.golden.receipt.each{k,v->check(j.data[k]==v,'Receipt value mismatch')};F.receipt_replay=[key:vars.get('s4.key'),version:F.version,data:j.data,event:j.event_id];F.receipt=j.data.receipt_id;F.version=j.data.version""",
    )
    if negative:
        http(
            tree,
            "NEG_RECEIPT_CHANGED_KEY_PAYLOAD",
            "POST",
            "/api/v1/batches/${batch_id}/receipt",
            "'recycler'",
            "F.golden.receipt + [actual_item_count:7]",
            expected="409",
            pre="vars.put('s4.key',F.receipt_replay.key);vars.put('s4.version',F.receipt_replay.version.toString())",
            verify="check(j.code=='IDEMPOTENCY_CONFLICT','Changed payload must conflict')",
            neg=True,
        )
    read_batch(tree, "VERIFIED")


def treatment(tree, label="SETUP_TREATMENT", sync=None):
    http(
        tree,
        label,
        "POST",
        "/api/v1/batches/${batch_id}/treatment",
        "'recycler'",
        "F.golden.treatment",
        sync=sync,
        verify="""check(j.data.batch_id==F.id && j.data.status=='RECYCLED' && j.data.version==F.version+1 && j.data.treatment_id && j.event_id,'Invalid treatment');metricCheck(j.data,F);check(j.data.evidence_status=='ABSENT','Optional evidence was fabricated');F.treatment_replay=[key:vars.get('s4.key'),version:F.version,data:j.data,event:j.event_id];F.treatment=j.data.treatment_id;F.source_event=j.event_id;F.version=j.data.version""",
    )


def replay(tree, op, path, role, body):
    http(
        tree,
        "REPLAY_" + op.upper(),
        "POST",
        path,
        role,
        body,
        pre="vars.put('s4.key',F."
        + op
        + "_replay.key);vars.put('s4.version',F."
        + op
        + "_replay.version.toString());vars.put('s4.assignment',F.assignment ?: '')",
        verify="check(j.data==F."
        + op
        + "_replay.data && j.event_id==F."
        + op
        + "_replay.event,'Replay changed durable identities')",
    )


def draft_to_matched(tree):
    http(
        tree,
        "SETUP_CREATE",
        "POST",
        "/api/v1/batches",
        "'donor'",
        "[category:'ICT_EQUIPMENT',quantity:5,estimated_weight_kg:12.00,condition_rating:'REPAIRABLE',is_data_bearing:true,zone:vars.get('s4_zone'),collection_deadline:Instant.now().plusSeconds(604800).toString(),notes:'S4LD:'+S.run+':'+F.scenario+':'+F.sequence]",
        expected="201",
        verify="check(j.data.batch_id && j.data.status=='DRAFT' && j.data.version==1,'Invalid draft');F.id=j.data.batch_id;F.version=j.data.version",
    )
    http(
        tree,
        "SETUP_SUBMIT",
        "POST",
        "/api/v1/batches/${batch_id}/submit",
        "'donor'",
        "[:]",
        verify="check(j.data.batch_id==F.id && j.data.status=='SUBMITTED' && j.data.version==F.version+1 && j.event_id,'Invalid submit');F.version=j.data.version;F.submit_event=j.event_id",
    )
    poll(tree, "MATCH")


def build():
    t = E.parse(PLAN)
    root = t.getroot().find("hashTree/hashTree")
    # Preserve original nodes verbatim in meaning. Remove only a previous generated extension.
    for n in list(root):
        if n.tag != "hashTree" and (n.get("testname") or "").startswith("S4 "):
            i = list(root).index(n)
            root.remove(root[i + 1])
            root.remove(n)
    args = root.find("Arguments/collectionProp")
    defaults = {
        "run_s4": "false",
        "s4_profile": "all",
        "s4_claim_threads": "2",
        "s4_handoff_threads": "2",
        "s4_burst_threads": "4",
        "s4_custody_threads": "4",
        "s4_custody_loops": "2",
        "s4_custody_pause_ms": "2000",
        "s4_ramp_seconds": "1",
        "s4_barrier_ms": "30000",
        "s4_start_spread_ms": "100",
        "s4_poll_timeout_seconds": "120",
        "s4_poll_interval_ms": "2000",
        "s4_connect_ms": "5000",
        "s4_response_ms": "10000",
        "s4_zone": "NORTH",
        "s4_output": "artifacts/jmeter/results/gui",
        "s4_data_file": "artifacts/jmeter/data/s4-golden.json",
    }
    for k, v in defaults.items():
        a = next((a for a in args if a.get("name") == k), None)
        if a is None:
            a = E.SubElement(args, "elementProp", name=k, elementType="Argument")
            prop(a, "Argument.name", k)
            prop(a, "Argument.metadata", "=")
            prop(a, "Argument.value", "${__P(" + k + "," + v + ")}")
    plan = t.getroot().find("hashTree/TestPlan")
    comment = plan.find('stringProp[@name="TestPlan.comments"]')
    comment.text = (
        (comment.text or "").split("\nSPRINT 4 EXTENSION\n")[0]
        + """\nSPRINT 4 EXTENSION
Added 15 October 2026 against local main-repository contracts. See artifacts/jmeter/README.md.
Groups S4 12-19 extend the existing plan; run_s4 defaults false. The CLI runner selects only these groups.
Claim race, same-assignment handoff race, independent five-wave processing burst, and custody reads
use native HTTP samplers. Setup/polls/replays/expected negatives have separate labels. Inline Groovy
prepares data and asserts results; no HTTP request is issued from Groovy. All durable fixtures are
created through APIs and tagged S4LD. SQL reconciliation remains required to prove exact row counts.
Existing User Defined Variables are preserved when regenerating the extension.
"""
    )
    setup = group(
        root,
        "S4 12 Prepare authenticated synthetic fixtures",
        profiles="all|claim|handoff|burst|custody",
    )
    script(
        setup,
        "SETUP_S4_INIT",
        """import groovy.json.JsonSlurper
import org.apache.jmeter.services.FileServer
import java.util.concurrent.*
def S=[run:'s4-'+UUID.randomUUID().toString().substring(0,8),host:(vars.get('host') ?: '').replaceAll('/+$',''),tokens:[:],failed:false,
 fixtures:[],processing:[],custody:[],records:Collections.synchronizedList([]),races:new ConcurrentHashMap(),arrivals:new ConcurrentHashMap(),profile:vars.get('s4_profile')]
props.put('s4.state',S)
// Only these controlled messages are exposed: never print an assertion or exception containing vars/secrets.
def problem='Unable to initialise S4 configuration'
def require={ok,msg->problem=msg;if(!ok)throw new IllegalArgumentException()}
def base=new File(FileServer.getFileServer().getBaseDir())
def planPath={value->
 def f=new File(value)
 if(f.isAbsolute())return f
 // Accept the original repository-relative defaults beside a JMX opened in the GUI.
 def relative=value.startsWith('artifacts/jmeter/') ? value.substring('artifacts/jmeter/'.length()) : value
 return new File(base,relative)
}
try {
 require(S.host ==~ /https?:\\/\\/[^\\s]+/, 'host must start with http:// or https://')
 ['s4_claim_threads','s4_handoff_threads','s4_burst_threads','s4_custody_threads'].each{
  require(vars.get(it)?.isInteger(),it+' must be an integer from 1 to 100')
  require(vars.get(it).toInteger()>=1 && vars.get(it).toInteger()<=100,it+' must be an integer from 1 to 100')
 }
 require(vars.get('s4_claim_threads').toInteger()>=2 && vars.get('s4_claim_threads').toInteger()%2==0,'s4_claim_threads must be even and at least 2')
 require(vars.get('s4_handoff_threads').toInteger()>=2,'s4_handoff_threads must be at least 2')
 require(vars.get('s4_burst_threads').toInteger()%4==0,'s4_burst_threads must be a multiple of 4')
 require(vars.get('s4_custody_loops')?.isInteger() && vars.get('s4_custody_loops').toInteger()>0,'s4_custody_loops must be a positive integer')
 require(vars.get('s4_data_file')?.trim(),'s4_data_file is empty; set the path to data/s4-golden.json')
 def data=planPath(vars.get('s4_data_file'))
 // Preserve launches that previously resolved custom relative data paths from the working directory.
 if(!data.isFile() && !new File(vars.get('s4_data_file')).isAbsolute())data=new File(vars.get('s4_data_file'))
 require(data.isFile() && data.canRead(),'s4_data_file was not found or is unreadable; use the full path to s4-golden.json')
 problem='s4_data_file must contain valid JSON with clean, discrepant, missing and zero cases in that order'
 S.golden=new JsonSlurper().parse(data).cases
 require(S.golden*.name==['clean','discrepant','missing','zero'],problem)
 def required=['donor','recycler']
 if(S.profile in ['all','claim'])required.add('recycler2')
 if(S.profile in ['all','handoff','burst','custody'])required.add('collector')
 if(S.profile in ['all','burst','custody'])required.add('auditor')
 S.roles=required
 required.each{r->
  require(vars.get(r+'_email')?.trim(),'Missing '+r+'_email; set it in User Defined Variables or the private properties file')
  require(vars.get(r+'_password'),'Missing '+r+'_password; set it in User Defined Variables or the private properties file')
 }
 require(vars.get('s4_output')?.trim(),'s4_output is empty; set a writable output folder')
 problem='Cannot create the S4 run directory under s4_output; set a writable output folder'
 def output=new File(planPath(vars.get('s4_output')),S.run)
 require(output.mkdirs(),problem)
 S.output=output
 vars.put('s4.login_count',required.size().toString());vars.put('s4.login_index','0')
 SampleResult.setSuccessful(true);SampleResult.setResponseCode('200');SampleResult.setResponseMessage('S4 configuration valid')
} catch(Exception|AssertionError e) {
 S.failed=true;SampleResult.setSuccessful(false);SampleResult.setResponseCode('CONFIG_FAILED')
 SampleResult.setResponseMessage(problem);SampleResult.setResponseData(problem,'UTF-8')
 log.warn('S4 configuration failed: '+problem);SampleResult.setStopTest(true)
}
""",
        wrap=False,
    )
    logins = loop(setup, "S4 setup logins", "${s4.login_count}")
    script(
        logins,
        "SETUP_AUTH_ROLE",
        "vars.put('s4.login_role',S.roles[vars.get('s4.login_index').toInteger()]);vars.put('s4.login_index',(vars.get('s4.login_index').toInteger()+1).toString())",
    )
    _, lh = http(
        logins,
        "SETUP_LOGIN",
        "POST",
        "/api/v1/auth/login",
        None,
        "[email:vars.get(vars.get('s4.login_role')+'_email'),password:vars.get(vars.get('s4.login_role')+'_password')]",
        verify="""check(j.access_token && j.refresh_token && j.expires_in>=600,'Invalid token or token lifetime below 10 minutes');def c=parse(new String(Base64.urlDecoder.decode(j.access_token.tokenize('.')[1]),'UTF-8'));def r=vars.get('s4.login_role');check(c.role==(r=='recycler2'?'RECYCLER':r.toUpperCase()) && c.org && c.sub,'Unexpected account role or identity');S.tokens[r]=[access:j.access_token,refresh:j.refresh_token,org:c.org,user:c.sub,expiry:c.exp]""",
        record=False,
    )
    timer, th = node(lh, "ConstantTimer", "S4 pace setup logins", "ConstantTimerGui")
    prop(timer, "ConstantTimer.delay", "${auth_pause_ms}")
    script(
        setup,
        "SETUP_BUILD_POOLS",
        """if(S.tokens.recycler2)check(S.tokens.recycler.org!=S.tokens.recycler2.org,'Claim contenders must belong to different recycler organisations')
def add={scenario,count,target-> (0..<count).each{i->def f=[scenario:scenario,sequence:i,golden:S.golden[i%4],version:1];S.fixtures.add(f);if(target != null)target.add(f)} }
if(S.profile in ['all','claim'])add('claim-race',1,null)
if(S.profile in ['all','handoff'])add('handoff-race',1,null)
if(S.profile in ['all','burst','custody'])add('processing',vars.get('s4_burst_threads').toInteger(),S.processing)
vars.put('s4.fixture_count',S.fixtures.size().toString());vars.put('s4.fixture_index','0')""",
    )
    fixtures = loop(setup, "S4 create API fixtures", "${s4.fixture_count}")
    script(
        fixtures,
        "SETUP_SELECT_FIXTURE",
        "def i=vars.get('s4.fixture_index').toInteger();vars.putObject('s4.fixture',S.fixtures[i]);vars.put('s4.fixture_index',(i+1).toString())",
    )
    draft_to_matched(fixtures)
    h = cond(
        fixtures, "${__groovy(vars.getObject('s4.fixture').scenario == 'claim-race')}"
    )
    http(
        h,
        "SETUP_CHECK_SECOND_RECYCLER",
        "GET",
        "/api/v1/opportunities/${batch_id}",
        "'recycler2'",
        verify="check(j.data.batch_id==F.id && j.data.status=='MATCHED' && j.data.version==F.version && j.data.claim_epoch==F.epoch,'Both recyclers must see the same opportunity')",
    )
    h = cond(
        fixtures, "${__groovy(vars.getObject('s4.fixture').scenario == 'handoff-race')}"
    )
    claim(h)
    assign(h)

    for num, kind, profiles in [
        (13, "claim", "all|claim"),
        (15, "handoff", "all|handoff"),
    ]:
        threads = "${s4_" + kind + "_threads}"
        h = group(root, "S4 " + str(num) + " " + kind + " race", threads, profiles)
        script(
            h,
            "AUX_BIND_" + kind.upper(),
            race_binding_script(kind),
            wrap=False,
        )
        label = "FCFS_CLAIM" if kind == "claim" else "RACE_HANDOFF"
        path = (
            "/api/v1/batches/${batch_id}/claim"
            if kind == "claim"
            else "/api/v1/assignments/${s4.assignment}/handoff"
        )
        body = (
            "[expected_version:F.version,claim_epoch:F.epoch]"
            if kind == "claim"
            else "F.handoff"
        )
        verify = (
            """if(prev.responseCode=='409')check(j.code in ['CONFLICT','STALE_VERSION'],'Unexpected losing race code')
else { check(j.data.batch_id==F.id,'Race returned wrong batch');"""
            + (
                "check(j.data.status=='APPROVED' && j.data.version==F.version+1 && j.data.claim_id && j.data.reservation_id && j.data.event_id,'Invalid winning claim')"
                if kind == "claim"
                else "check(j.data.assignment_id==F.assignment && j.data.assignment_status=='COMPLETED' && j.event_id,'Invalid winning handoff')"
            )
            + """ }
S.races['"""
            + kind
            + """'].add([http:prev.responseCode,start:prev.startTime,end:prev.endTime,role:vars.get('s4.role'),key:vars.get('s4.key'),version:F.version,body:parse(vars.get('s4.body')),data:j.data,event:j.event_id])"""
        )
        http(
            h,
            label,
            "POST",
            path,
            "vars.get('s4.race_role')",
            body,
            expected="200|409",
            verify=verify,
            sync=threads,
            neg=True,
        )
        h = group(
            root,
            "S4 " + str(num + 1) + " " + kind + " winner verification",
            profiles=profiles,
        )
        script(
            h,
            "AUX_ASSERT_" + kind.upper() + "_RACE",
            """def rows=S.races['"""
            + kind
            + """']?.toList() ?: [];def n=vars.get('s4_"""
            + kind
            + """_threads').toInteger()
check(rows.size()==n && rows.count{it.http=='200'}==1 && rows.count{it.http=='409'}==n-1,'Race must have exactly one winner and N-1 conflicts')
check(rows*.start.max()-rows*.start.min()<=vars.get('s4_start_spread_ms').toLong(),'Race start spread exceeds limit; invalid concurrency evidence')
check(rows.any{a->rows.any{b->a.key!=b.key && """
            + ("a.role!=b.role && " if kind == "claim" else "")
            + """Math.max(a.start,b.start)<Math.min(a.end,b.end)}},'Race requests did not overlap')
def f=S.fixtures.find{it.scenario=='"""
            + kind
            + """-race'};vars.putObject('s4.fixture',f);def w=rows.find{it.http=='200'};vars.putObject('s4.winner',w);vars.put('s4.assignment',f.assignment ?: '')""",
        )
        http(
            h,
            "REPLAY_" + kind.upper() + "_WINNER",
            "POST",
            path,
            "vars.getObject('s4.winner').role",
            "vars.getObject('s4.winner').body",
            pre="def w=vars.getObject('s4.winner');vars.put('s4.key',w.key);vars.put('s4.version',w.version.toString())",
            verify="def w=vars.getObject('s4.winner');check(j.data==w.data && j.event_id==w.event,'Winner replay changed durable identities')",
        )
        script(h, "AUX_ADVANCE_" + kind.upper(), "F.version=F.version+1")
        read_batch(h, "APPROVED" if kind == "claim" else "COLLECTED")

    h = group(
        root,
        "S4 17 Independent processing waves",
        "${s4_burst_threads}",
        "all|burst|custody",
    )
    script(
        h,
        "AUX_BIND_PROCESSING",
        "check(S.tokens.values().every{it.expiry > Instant.now().epochSecond+180},'Token lifetime insufficient after setup; reduce fixture count or increase test access-token lifetime');check(S.processing.size()==vars.get('s4_burst_threads').toInteger(),'Incomplete processing fixture pool');vars.putObject('s4.fixture',S.processing[ctx.threadNum])",
    )
    claim(h, "TX_CLAIM", "${s4_burst_threads}")
    assign(h, "TX_ASSIGN", "${s4_burst_threads}")
    handoff(h, "TX_HANDOFF", "${s4_burst_threads}")
    receipt(h, "TX_RECEIPT", "${s4_burst_threads}", True)
    treatment(h, "TX_TREATMENT", "${s4_burst_threads}")
    poll(h, "COMPLETION")
    replay(
        h,
        "handoff",
        "/api/v1/assignments/${s4.assignment}/handoff",
        "'collector'",
        "F.handoff",
    )
    replay(
        h,
        "receipt",
        "/api/v1/batches/${batch_id}/receipt",
        "'recycler'",
        "F.golden.receipt",
    )
    replay(
        h,
        "treatment",
        "/api/v1/batches/${batch_id}/treatment",
        "'recycler'",
        "F.golden.treatment",
    )
    http(
        h,
        "NEG_DONOR_CUSTODY_READ",
        "GET",
        "/api/v1/audit/batches/${batch_id}/timeline?page=1&page_size=100",
        "'donor'",
        expected="403",
        verify="check(j.code=='FORBIDDEN','Donor obtained auditor access')",
        neg=True,
    )
    script(
        h, "AUX_STORE_COMPLETED_FIXTURE", "synchronized(S.custody){S.custody.add(F)}"
    )

    h = group(
        root, "S4 18 Concurrent custody reads", "${s4_custody_threads}", "all|custody"
    )
    script(
        h,
        "AUX_VERIFY_CUSTODY_POOL",
        "check(S.custody.size()==vars.get('s4_burst_threads').toInteger() && S.custody.every{it.completed},'Read pool not complete');vars.put('s4.read_index',ctx.threadNum.toString())",
    )
    h = loop(h, "S4 bounded custody cycles", "${s4_custody_loops}")
    script(
        h,
        "AUX_ROTATE_CUSTODY_FIXTURE",
        "def i=vars.get('s4.read_index').toInteger();vars.putObject('s4.fixture',S.custody[i%S.custody.size()]);vars.put('s4.read_index',(i+1).toString())",
    )
    for label in ["STD_TIMELINE", "STD_TIMELINE", "STD_ANOMALIES", "STD_IMPACT"]:
        path = (
            "/api/v1/audit/impact"
            if label == "STD_IMPACT"
            else "/api/v1/audit/batches/${batch_id}/"
            + ("timeline" if label == "STD_TIMELINE" else "anomalies")
            + "?page=1&page_size=100"
        )
        if label == "STD_TIMELINE":
            v = """check(j.data instanceof List && j.total_count==j.data.size() && j.data.every{it.batch_id==F.id && it.audit_id && it.command_id && it.correlation_id && it.occurred_at},'Invalid or truncated custody timeline');['CollectionCompleted','ReceiptVerified','TreatmentRecorded','AnalyticsCompleted'].each{e->check(j.data.count{it.event_type==e}==1,'Missing/duplicate custody transition '+e)};def ids=j.data*.audit_id.sort();synchronized(F){if(F.timeline_ids)check(F.timeline_ids==ids,'Custody changed during reads');else F.timeline_ids=ids}"""
        elif label == "STD_ANOMALIES":
            v = """check(j.data instanceof List && j.total_count==j.data.size() && j.data.every{it.batch_id==F.id && it.anomaly_id && it.result_id},'Invalid anomaly list');check(j.data*.code.sort(false)==F.golden.flags.sort(false),'Persisted flags mismatch')"""
        else:
            v = """check(j.data.items instanceof List && j.data.total_count==j.data.items.size() && j.data.totals instanceof Map && j.data.filter instanceof Map,'Invalid impact wrapper');def items=j.data.items.findAll{it.batch_id==F.id};check(items.size()==1,'Missing or duplicate per-batch impact');def item=items[0];check(item.source_event_id==F.source_event && item.receipt_id==F.receipt && item.treatment_id==F.treatment && item.rule_version=='d3-v1' && item.result_id && item.input_hash,'Impact identity mismatch');metricCheck(item.metrics+[data_quality:item.data_quality],F);F.golden.analytics_metrics.each{k,v->check(item.metrics[k]==v,'Analytics metric mismatch: '+k)};check(item.anomaly_codes.sort(false)==F.golden.flags.sort(false),'Impact flags mismatch');synchronized(F){if(F.result_id)check(F.result_id==item.result_id,'Impact identity changed');else F.result_id=item.result_id}"""
        _, ch = http(h, label, "GET", path, "'auditor'", verify=v)
        tim, th = node(ch, "ConstantTimer", "S4 custody pacing", "ConstantTimerGui")
        prop(tim, "ConstantTimer.delay", "${s4_custody_pause_ms}")
    http(
        h,
        "AUX_VERIFY_CUSTODY_UNCHANGED",
        "GET",
        "/api/v1/processing/batches/${batch_id}",
        "'recycler'",
        verify="check(j.data.batch_id==F.id && j.data.status=='COMPLETED' && j.data.version==F.completed_version,'Read workload changed lifecycle');metricCheck(j.data,F)",
    )

    h = group(
        root,
        "S4 19 Export manifest and clear runtime credentials",
        profiles="all|claim|handoff|burst|custody",
        tag="PostThreadGroup",
    )
    script(
        h,
        "AUX_EXPORT_S4_EVIDENCE",
        """if(S?.output) {
 def clean=S.fixtures.collect{f->f.findAll{k,v->!(k in ['handoff_replay','receipt_replay','treatment_replay','handoff'])}}
 new File(S.output,'manifest.json').text=json([run_id:S.run,host:S.host,profile:S.profile,fixtures:clean,races:S.races,application_evidence:'SQL reconciliation required',failed:S.failed])
 new File(S.output,'result.json').text=json([http_assertions:S.failed?'FAIL':'PASS',sql_integrity:'NOT_RUN',event_latency:'NOT_MEASURED'])
}
if(S)S.tokens.clear()
props.remove('s4.state')""",
    )
    E.indent(t, space="  ")
    t.write(PLAN, encoding="UTF-8", xml_declaration=True)
    with PLAN.open("a") as f:
        f.write("\n")


if __name__ == "__main__":
    build()
