import React from 'react';

// Documentation / download links.
const TARM = 'https://www.ibm.com/docs/en/tarm/8.21.2?topic=';
const LINKS = {
  turboInstallOverview: `${TARM}deployment-installing-self-hosted-turbonomic`,
  turboDocs: 'https://www.ibm.com/docs/en/tarm/8.21.2',
  wmiUserAccount: 'https://www.ibm.com/docs/en/tarm/8.21.3?topic=wmi-creating-user-account',
  wmiEnabling: 'https://www.ibm.com/docs/en/tarm/8.21.3?topic=wmi-enabling',
  turboDownloads: 'https://community.ibm.com/community/user/viewdocument/turbonomic-latest-releases-downlo?CommunityKey=8e1487dd-98f9-435f-adc6-7a37d8b9b217&tab=librarydocuments',
};

// Ways to install a self-hosted Turbonomic, as listed under "Installing self-hosted Turbonomic" in the IBM docs.
const INSTALL_OPTIONS = [
  { name: 'Hyper-V using a VHD image', platform: 'Virtual machine image (VHD)', topic: 'turbonomic-installing-hyper-v-using-vhd-image', title: 'Installing Turbonomic on Hyper-V using a VHD image' },
  { name: 'vCenter or vSphere using an OVA image', platform: 'Virtual machine image (OVA)', topic: 'turbonomic-installing-vcenter-vsphere-using-ova-image', title: 'Installing Turbonomic on vCenter or vSphere using an OVA image' },
];

const A = ({ href, children }) => (
  <a href={href} target="_blank" rel="noreferrer">{children}</a>
);

const MANUAL = [
  {
    title: 'A Turbonomic instance with a reachable URL and admin credentials',
    body: (
      <>
        The wizard authenticates to the Turbonomic API (<code>/api/v3/login</code>) over HTTPS. Use an existing SaaS
        tenant, or install a self-hosted instance using one of the options under Installation of Turbonomic.
      </>
    ),
  },
  {
    title: 'Network access from the container',
    body: (
      <>
        The container host must allow outbound HTTPS (443) to Turbonomic; WinRM 5985/5986 to Windows target VMs;
        SSH 22 to Linux target VMs. The default NAT network routes this traffic through the host; see DOCKER.md for
        transparent / l2bridge networks.
      </>
    ),
  },
  {
    title: 'Target VMs already discovered in Turbonomic',
    body: <>VM names entered in step 3 must match the names Turbonomic discovered from your cloud / hypervisor target.</>,
  },
  {
    title: 'Target Windows VMs hardened for WMI',
    body: (
      <>
        For the WMI configuration, see <A href={LINKS.wmiUserAccount}>Creating a WMI user account</A> and{' '}
        <A href={LINKS.wmiEnabling}>Enabling WMI</A>.
      </>
    ),
  },
];

export default function Prerequisites() {
  return (
    <div className="card">
      <h2>Prerequisites</h2>
      <p className="lead">
        This app runs in a Windows container that already includes Node.js, PowerShell 7, Python and the toolkit
        scripts. Confirm the items below before you start the wizard.
      </p>

      <h3>Installation of Turbonomic</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Skip this section if you already have a Turbonomic instance (for example Turbonomic SaaS). Otherwise choose the
        installation method that matches your environment. See <A href={LINKS.turboInstallOverview}>Installing self-hosted Turbonomic</A> for
        the overview and requirements.
      </p>
      <table>
        <thead><tr><th>Install Turbonomic on</th><th>Type</th><th>Installation guide</th><th>Downloads</th></tr></thead>
        <tbody>
          {INSTALL_OPTIONS.map((o) => (
            <tr key={o.topic}>
              <td>{o.name}</td>
              <td>{o.platform}</td>
              <td><A href={`${TARM}${o.topic}`}>{o.title}</A></td>
              <td style={{ textAlign: 'center' }}>
                <a href={LINKS.turboDownloads} target="_blank" rel="noreferrer" title="Turbonomic latest releases downloads" aria-label={`Download Turbonomic for ${o.name}`} style={{ fontSize: 26, fontWeight: 900, lineHeight: 1, textDecoration: 'none', WebkitTextStroke: '1.5px currentColor' }}>&#8595;</a>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <h3>Other prerequisites</h3>
      <ol className="steps">
        {MANUAL.map((m) => (
          <li key={m.title}><strong>{m.title}.</strong> {m.body}</li>
        ))}
      </ol>
    </div>
  );
}
