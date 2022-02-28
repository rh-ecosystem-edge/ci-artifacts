import sys
import secrets

from toolbox._common import PlaybookRun


class OCMAddon:
    """
    Commands for managing OCM addons
    """
    @staticmethod
    def install(ocm_refresh_token, ocm_cluster_id, ocm_url, ocm_addon_id, wait_for_ready_state=False):
        """
        Installs an OCM addon

        Args:
            ocm_refresh_token: For OCM login auth
            ocm_cluster_id: Cluster ID from OCM's POV
            ocm_url: Used to determine environment
            ocm_addon_id: the addon id to install. (such as `managed-odh`, `gpu-operator-certified-addon` etc.)
            wait_for_ready_state: Optional. If true will cause the role to wait until addon reports ready state. (Can time out)
        """
        opt = {
            "ocm_addon_id": ocm_addon_id,
            "ocm_cluster_id": ocm_cluster_id,
            "ocm_url": ocm_url,
            "ocm_refresh_token": ocm_refresh_token,
            "wait_for_ready_state": wait_for_ready_state,
        }
        return PlaybookRun("ocm_install_addon", opt)

