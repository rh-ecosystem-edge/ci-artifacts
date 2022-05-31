import sys
import secrets

from toolbox._common import PlaybookRun


class OCMAddon:
    """
    Commands for managing OCM addons
    """
    @staticmethod
    def install(ocm_cluster_id, ocm_url, ocm_addon_id, ocm_addon_params=[], wait_for_ready_state=False):
        """
        Installs an OCM addon

        Args:
            ocm_cluster_id: Cluster ID from OCM's POV
            ocm_url: Used to determine environment
            ocm_addon_id: the addon id to install. (such as `managed-odh`, `gpu-operator-certified-addon` etc.)
            ocm_addon_params: Optional. list of dicts i.e [{"id":"something","value":"something"},{"id":"something_else","value":"we-get-it"}]
            wait_for_ready_state: Optional. If true will cause the role to wait until addon reports ready state. (Can time out)

        """
        opt = {
            "ocm_addon_id": ocm_addon_id,
            "ocm_cluster_id": ocm_cluster_id,
            "ocm_url": ocm_url,
            "ocm_addon_params": ocm_addon_params,
            "wait_for_ready_state": wait_for_ready_state,
        }
        return PlaybookRun("ocm_install_addon", opt)

    @staticmethod
    def remove(ocm_cluster_id, ocm_url, ocm_addon_id, wait_until_removed=False):
        """
        Removes an OCM addon

        Args:
            ocm_cluster_id: Cluster ID from OCM's POV
            ocm_url: Used to determine environment
            ocm_addon_id: the addon id to install. (such as `managed-odh`, `gpu-operator-certified-addon` etc.)
            wait_until_removed: Optional. If true will cause the role to wait until addon is removed from cluster. (Can time out)

        """
        opt = {
            "ocm_addon_id": ocm_addon_id,
            "ocm_cluster_id": ocm_cluster_id,
            "ocm_url": ocm_url,
            "wait_until_removed": wait_until_removed,
        }
        return PlaybookRun("ocm_remove_addon", opt)

