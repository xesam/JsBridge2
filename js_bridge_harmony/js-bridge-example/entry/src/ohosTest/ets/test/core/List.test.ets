import conformanceCoreBaselineTest from './ConformanceCoreBaseline.test';
import sessionServiceTest from './SessionServiceTest.test';
import policyGroupsTest from './PolicyGroupsTest.test';

// 由 scripts/test_harmony.sh 从 js-bridge-core/src/test 同步（import 重写为 HAR 包名）；
// 与四端 bridge-client-conformance.cases.js 副本同款的"单源多副本 + 脚本同步"模式。
export default function coreSuites(): void {
    conformanceCoreBaselineTest();
    sessionServiceTest();
    policyGroupsTest();
}
