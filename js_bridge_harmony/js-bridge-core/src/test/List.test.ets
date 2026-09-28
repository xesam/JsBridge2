import conformanceCoreBaselineTest from './ConformanceCoreBaseline.test';
import sessionServiceTest from './SessionServiceTest.test';
import policyGroupsTest from './PolicyGroupsTest.test';

export default function testsuite(): void {
  conformanceCoreBaselineTest();
  sessionServiceTest();
  policyGroupsTest();
}
