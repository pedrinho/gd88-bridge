// Unit-test runner: tools/test.sh builds it with swiftc from src/*.swift (except main.swift) + tests/*.swift.
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

runPrinterStreamTests()
runStatusTests()
runRawValidatorTests()
runRasterTests()
runESCPOSTests()
runIPPCodecTests()
runHTTPTests()
runJobQueueTests()
runIPPServiceTests()

print("\n\(testChecks) checks, \(testFailures) failed")
exit(testFailures == 0 ? 0 : 1)
