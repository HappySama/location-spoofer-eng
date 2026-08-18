import Foundation

enum GitHubSubmission {
    static let communityContributionURL = URL(
        string: "https://github.com/xweiba/location-spoofer/discussions/new?category=%E7%AC%AC%E4%B8%89%E6%96%B9%E9%85%8D%E7%BD%AE%E5%88%86%E4%BA%AB"
    )!
    static let usageHelpURL = URL(
        string: "https://github.com/xweiba/location-spoofer/discussions/categories/%E4%BD%BF%E7%94%A8%E5%B8%AE%E5%8A%A9"
    )!
    static let featureRequestURL = URL(
        string: "https://github.com/xweiba/location-spoofer/discussions/categories/%E5%8A%9F%E8%83%BD%E5%BB%BA%E8%AE%AE"
    )!
    static let bugReportURL = URL(
        string: "https://github.com/xweiba/location-spoofer/issues/new?template=bug-report.yml"
    )!

    static func communityContributionTemplate(
        for client: ThirdPartyProxyClient,
        systemVersion: String
    ) -> String {
        """
        ## Third-Party Client
        \(client.name)

        ## Third-Party Client Version
        Enter the version of the third-party client you are using.

        ## iOS Version
        iOS \(systemVersion)

        ## Configuration Steps
        Describe the module import, certificate or HTTPS decryption settings, proxy connection, and final verification process.

        ## Screenshots and Additional Notes
        Attach original screenshots with sensitive information removed, and explain which step each image shows.

        ## README Credit
        - [ ] Include this anonymously and do not show my GitHub account in the README
        """
    }
}
