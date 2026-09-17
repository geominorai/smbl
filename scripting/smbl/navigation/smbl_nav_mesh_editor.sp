#pragma semicolon 1

#define DEBUG

#define PLUGIN_AUTHOR "AI"
#define PLUGIN_VERSION "0.1.1"

#include <sourcemod>
#include <sdktools>

#include <smlib/effects>
#include <smlib/entities>

#include <smbl/nav_mesh>

#define GRID_SIZE	5.0

#define COLOR_DEFAULT	{255, 255, 255, 0}
#define COLOR_WHITE		{255, 255, 255, 255}
#define COLOR_RED		{255, 0, 0, 255}
#define COLOR_GREEN		{0, 255, 0, 255}
#define COLOR_BLUE		{0, 0, 255, 255}
#define COLOR_YELLOW	{255, 255, 0, 255}
#define COLOR_MAGENTA	{255, 0, 255, 255}
#define COLOR_CYAN		{0, 255, 255, 255}
#define COLOR_ORANGE	{127, 31, 0, 255}

#define CROSSHAIR_SIZE	25.0

#define ANG_DOWN		{90.0, 0.0, 0.0}

#define MIN_VERTICES		3
#define MAX_VERTICES		8
#define DEFAULT_VERTICES	4

#define MIN_SNAP_GRID		1
#define MAX_SNAP_GRID		16
#define SNAP_GRID_INCREMENT	2

#define NODE_PROXIMITY	500.0

#define POSITIVE_INFINITY	view_as<float>(0x7F800000)

enum EditMode {
	EditMode_Off = 0,
	EditMode_Default,
	EditMode_Add,
	EditMode_Edit,
	EditMode_EditAttachmentsList,
	EditMode_EditAttachment,
	EditMode_EditAttachmentAttributes
}

enum struct NavEdit {
	EditMode iEditMode;
	NavNode mSelectedNode;
	NavNode mSelectedNode2;
	int iSelectedVertex;
	int iSelectedEdge;
	int iSelectedEdge2;
	int iSelectedAttachment;

	int iSnapToGrid;
	int iVertices;
	float vecAimPos[3];
	float vecNodeOrigin[3];

	int iCurrentVertex;
	float vecVertices[MAX_VERTICES*3];

	bool bStartedCenter;

	bool bStartedDiagonal;
	float vecDiagStart[3];

	void GetVertex(int i, float vecVertex[3]) {
		int iOffset = 3*i;
		vecVertex[0] = this.vecVertices[iOffset  ];
		vecVertex[1] = this.vecVertices[iOffset+1];
		vecVertex[2] = this.vecVertices[iOffset+2];
	}

	void SetVertex(int i, float vecVertex[3]) {
		int iOffset = 3*i;
		this.vecVertices[iOffset  ] = vecVertex[0];
		this.vecVertices[iOffset+1] = vecVertex[1];
		this.vecVertices[iOffset+2] = vecVertex[2];
	}
}

NavEdit g_eNavEdit[MAXPLAYERS+1];

enum Orientation {
	Orientation_Colinear,
	Orientation_Clockwise,
	Orientation_CounterClockwise,
}

NavMesh g_mNavMesh;

// Pair with FL_ATTACH_ flags in smbl/nav_mesh.inc
char g_sAttachFlags[][32] = {
	"Blocked",			// 0
	"Ground",			// 1
	"Solid",			// 2
	"Wall",				// 3
	"Low Clearance",	// 4
	"Air Gap",			// 5
	"Must Duck",		// 6
	"Must Jump",		// 7
	"Precise",			// 8
	"Drop"				// 9
};

// Pair with FL_NODE_ flags in smbl/nav_mesh.inc
char g_sNodeFlags[][32] = {
	"Uncharted",		// 0
	"Avoid",			// 1
	"Hazard",			// 2
	"Unsurvivable",		// 3
	"Transient"			// 4
};

int g_iLaser;
int g_iHalo;

public Plugin myinfo = {
	name = "SMBL NavMesh Editor",
	author = PLUGIN_AUTHOR,
	description = "Navigation mesh editor",
	version = PLUGIN_VERSION,
	url = "https://jumpacademy.tf"
};

public void OnPluginStart() {
	CreateConVar("smbl_nav_editor_version", PLUGIN_VERSION, "SMBL navigation mesh version -- Do not modify", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	RegAdminCmd("smbl_nav_edit", cmdNavEdit, ADMFLAG_ROOT, "Open navigation mesh edit menu");
	RegAdminCmd("smbl_nav_edit_load", cmdNavEditLoad, ADMFLAG_ROOT, "Load navigation mesh from file");
	RegAdminCmd("smbl_nav_edit_save", cmdNavEditSave, ADMFLAG_ROOT, "Save navigation mesh to file");
	RegAdminCmd("smbl_nav_edit_clear", cmdNavEditClear, ADMFLAG_ROOT, "Clear navigation mesh");
	
	// Late plugin load
	if (GetGameTime() > 5.0) {
		for (int i=1; i<=MaxClients; i++) {
			if (IsClientInGame(i) && !IsFakeClient(i)) {
				ResetClient(i);
			}
		}
	}
}

public void OnPluginEnd() {
	NavMesh.Destroy(g_mNavMesh);
}

public void OnLibraryAdded(const char[] sName) {
	if (StrEqual(sName, "smbl_nav_mesh")) {
		g_mNavMesh = NavMesh.Instance();
	}
}

public void OnMapStart() {
	g_iLaser = PrecacheModel("sprites/laserbeam.vmt");
	g_iHalo = PrecacheModel("materials/sprites/halo01.vmt");

	g_mNavMesh = NavMesh.Instance();
}

public void OnMapEnd() {
	for (int i=1; i<=MaxClients; i++) {
		ResetClient(i);
	}

	NavMesh.Destroy(g_mNavMesh);
}

public void OnClientConnected(int iClient) {
	ResetClient(iClient);
}

public void OnClientDisconnect(int iClient) {
}

public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, float vecVel[3], float vecAng[3], int &iWeapon) {
	if (g_eNavEdit[iClient].iEditMode == EditMode_Off) {
		return Plugin_Continue;
	}

	float vecPos[3];
	GetClientEyePosition(iClient, vecPos);

	float vecAimPos[3];
	GetTraceEndpoint(vecPos, vecAng, vecAimPos);

	if (g_eNavEdit[iClient].iSnapToGrid) {
		SnapToGrid(vecAimPos, g_eNavEdit[iClient].iSnapToGrid);
	}

	g_eNavEdit[iClient].vecAimPos = vecAimPos;

	switch (g_eNavEdit[iClient].iEditMode) {
		case EditMode_Default, EditMode_Add: {
			NavNode mNearestNode = GetNearestNode(vecAimPos);
			if (mNearestNode) {
// 				DrawNode(mNearestNode, COLOR_YELLOW);
				DrawNode(mNearestNode);
				DrawAttachedNodes(mNearestNode);

				float vecVertices[MAX_VERTICES][3];
				int iVertices;
				mNearestNode.GetVertices(vecVertices, iVertices);

				float vecOrigin[3];
				mNearestNode.GetOrigin(vecOrigin);

				for (int i=0; i<iVertices; i++) {
					SubtractVectors(vecVertices[i], vecOrigin, vecVertices[i]);
					ScaleVector(vecVertices[i], 0.9);
					AddVectors(vecVertices[i], vecOrigin, vecVertices[i]);
				}

				DrawHull(vecVertices, iVertices, COLOR_YELLOW);
			}

			g_eNavEdit[iClient].mSelectedNode = mNearestNode;
		}
	}

	// Edit mode

	switch (g_eNavEdit[iClient].iEditMode) {
		case EditMode_Default: {
			SendNavEditPanel(iClient);
		}
		case EditMode_Add: {
			SendAddNodePanel(iClient);

			DrawAimCross(vecAimPos);

			if (g_eNavEdit[iClient].iCurrentVertex >= 0) {
				if (g_eNavEdit[iClient].iCurrentVertex < 2) {
					float vecFirstVertex[3];
					g_eNavEdit[iClient].GetVertex(0, vecFirstVertex);

					DrawDebugLine(vecFirstVertex, vecAimPos, COLOR_WHITE);
				} else {
					static float vecPoints[MAX_VERTICES][3];

					for (int i=0; i<g_eNavEdit[iClient].iCurrentVertex; i++) {
						g_eNavEdit[iClient].GetVertex(i, vecPoints[i]);
					}

					static float vecHull[MAX_VERTICES][3];
					static int iHullVertices;
					vecPoints[g_eNavEdit[iClient].iCurrentVertex] = vecAimPos;
					GetConvexHull(vecPoints, g_eNavEdit[iClient].iCurrentVertex+1, vecHull, iHullVertices);

					DrawHull(vecHull, iHullVertices, COLOR_WHITE);
				}
			} else if (g_eNavEdit[iClient].bStartedCenter || g_eNavEdit[iClient].bStartedDiagonal) {
				float fPiDiv = FLOAT_PI / g_eNavEdit[iClient].iVertices;
				float fAngSegment = 2 * fPiDiv;

				if (g_eNavEdit[iClient].bStartedDiagonal) {
					if (g_eNavEdit[iClient].iVertices % 2) {
						float vecDir[3];
						SubtractVectors(vecAimPos, g_eNavEdit[iClient].vecDiagStart, vecDir);
						vecDir[2] = 0.0;

						float fDiagLength = GetVectorLength2D(vecDir);

						float fCosPiDiv = Cosine(fPiDiv);
						float fRadius = fDiagLength / (1.0 + fCosPiDiv);
						float fApothem = fRadius * fCosPiDiv;

						if (iButtons & IN_DUCK) {
							float vecDiffAng[3];
							GetVectorAngles(vecDir, vecDiffAng);
							float fAngOffset = RoundToNearest(DegToRad(vecDiffAng[1]) / fPiDiv) * fPiDiv;

							vecDir[0] = Cosine(fAngOffset);
							vecDir[1] = Sine(fAngOffset);
						} else {
							NormalizeVector(vecDir, vecDir);
						}

						ScaleVector(vecDir, fApothem);

						AddVectors(g_eNavEdit[iClient].vecDiagStart, vecDir, g_eNavEdit[iClient].vecNodeOrigin);

						if (iButtons & IN_DUCK) {
							NormalizeVector(vecDir, vecDir);
							ScaleVector(vecDir, fDiagLength);
							AddVectors(g_eNavEdit[iClient].vecDiagStart, vecDir, vecAimPos);
						}
					} else {
						if (iButtons & IN_DUCK) {
							float vecDir[3];
							SubtractVectors(vecAimPos, g_eNavEdit[iClient].vecDiagStart, vecDir);
							vecDir[2] = 0.0;

							float fDiagLength = GetVectorLength2D(vecDir);

							float vecDiffAng[3];
							GetVectorAngles(vecDir, vecDiffAng);
							float fAngOffset = RoundToNearest(DegToRad(vecDiffAng[1]) / fPiDiv) * fPiDiv;

							vecDir[0] = Cosine(fAngOffset);
							vecDir[1] = Sine(fAngOffset);

							ScaleVector(vecDir, fDiagLength);

							AddVectors(g_eNavEdit[iClient].vecDiagStart, vecDir, vecAimPos);
						}

						AddVectors(g_eNavEdit[iClient].vecDiagStart, vecAimPos, g_eNavEdit[iClient].vecNodeOrigin);
						ScaleVector(g_eNavEdit[iClient].vecNodeOrigin, 0.5);
					}
				}

				float vecDiff[3];
				SubtractVectors(vecAimPos, g_eNavEdit[iClient].vecNodeOrigin, vecDiff);

				float fRadius = GetVectorLength2D(vecDiff);

				float vecDiffAng[3];
				GetVectorAngles(vecDiff, vecDiffAng);
				float fAngOffset = DegToRad(vecDiffAng[1]);

				if (iButtons & IN_DUCK) {
					if (g_eNavEdit[iClient].bStartedCenter) {
						fAngOffset = RoundToNearest(fAngOffset / (0.5*fAngSegment)) * 0.5*fAngSegment;
					} else if (g_eNavEdit[iClient].bStartedDiagonal) {
						fAngOffset = RoundToNearest(fAngOffset / fPiDiv) * fPiDiv;
					}
				}

				float vecFirstVertex[3], vecLastVertex[3];

				for (int i=0; i<g_eNavEdit[iClient].iVertices; i++) {
					float fAngXY = fAngSegment * i;

					float vecVertex[3];
					vecVertex[0] = g_eNavEdit[iClient].vecNodeOrigin[0] + fRadius * Cosine(fAngOffset + fAngXY);
					vecVertex[1] = g_eNavEdit[iClient].vecNodeOrigin[1] + fRadius * Sine(fAngOffset + fAngXY);
					vecVertex[2] = g_eNavEdit[iClient].vecNodeOrigin[2];

					float vecTraceStart[3];
					vecTraceStart[0] = vecVertex[0];
					vecTraceStart[1] = vecVertex[1];
					vecTraceStart[2] = vecVertex[2] + 50.0;

					float vecTraceEnd[3];
					if (GetTraceEndpoint(vecTraceStart, {90.0, 00.0, 0.0}, vecTraceEnd)) {
						vecVertex[2] = vecTraceEnd[2];
					}

					g_eNavEdit[iClient].SetVertex(i, vecVertex);

					if (i > 0) {
						DrawDebugLine(vecLastVertex, vecVertex, COLOR_WHITE);
					} else {
						vecFirstVertex = vecVertex;
					}

					vecLastVertex = vecVertex;
				}

				DrawDebugLine(vecLastVertex, vecFirstVertex, COLOR_WHITE);

				if (g_eNavEdit[iClient].bStartedDiagonal) {
					DrawDebugLine(g_eNavEdit[iClient].vecDiagStart, vecAimPos, COLOR_YELLOW);
				} else {
					float vecEndPos[3];
					vecEndPos = g_eNavEdit[iClient].vecNodeOrigin;
					vecEndPos[0] += fRadius * Cosine(fAngOffset);
					vecEndPos[1] += fRadius * Sine(fAngOffset);

					float vecTraceStart[3];
					vecTraceStart[0] = vecEndPos[0];
					vecTraceStart[1] = vecEndPos[1];
					vecTraceStart[2] = vecEndPos[2] + 50.0;

					float vecTraceEnd[3];
					if (GetTraceEndpoint(vecTraceStart, {90.0, 00.0, 0.0}, vecTraceEnd)) {
						vecEndPos[2] = vecTraceEnd[2];
					}

					DrawDebugLine(g_eNavEdit[iClient].vecNodeOrigin, vecEndPos, COLOR_YELLOW);
				}
			}
		}
		case EditMode_Edit: {
			SendEditNodePanel(iClient);

			NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;

			float vecPoint[3];

			int iVertices = mSelectedNode.iVertices;

			int iClosestVertex = 0;
			mSelectedNode.GetVertex(0, vecPoint);

			float fMinVertexDistance = GetVectorDistance(vecAimPos, vecPoint);
			for (int i=1; i<iVertices; i++) {
				mSelectedNode.GetVertex(i, vecPoint);
				float fDistance = GetVectorDistance(vecAimPos, vecPoint);
				if (fDistance < fMinVertexDistance) {
					fMinVertexDistance = fDistance;
					iClosestVertex = i;
				}
			}

			int iClosestEdge = 0;
			mSelectedNode.GetEdgeCenter(0, vecPoint);

			float fMinEdgeDistance = GetVectorDistance(vecAimPos, vecPoint);
			for (int i=1; i<iVertices; i++) {
				mSelectedNode.GetEdgeCenter(i, vecPoint);
				float fDistance = GetVectorDistance(vecAimPos, vecPoint);
				if (fDistance < fMinEdgeDistance) {
					fMinEdgeDistance = fDistance;
					iClosestEdge = i;
				}
			}

			if (fMinVertexDistance < fMinEdgeDistance) {
				float vecVertexA[3], vecVertexB[3];
				mSelectedNode.GetVertex(iClosestVertex, vecVertexA);

				vecVertexB = vecVertexA;
				vecVertexB[2] += 25.0;

				DrawDebugLine(vecVertexA, vecVertexB, COLOR_YELLOW, 0.1, 1.0);

				g_eNavEdit[iClient].iSelectedVertex = iClosestVertex;				
				g_eNavEdit[iClient].iSelectedEdge = -1;

				DrawNode(mSelectedNode);
			} else {
				g_eNavEdit[iClient].iSelectedVertex = -1;
				g_eNavEdit[iClient].iSelectedEdge = iClosestEdge;

				int iColors[MAX_VERTICES][4];
				for (int i=0; i<iVertices; i++) {
					iColors[i] = (i == iClosestEdge) ? COLOR_YELLOW : COLOR_DEFAULT;
				}
				
				DrawColoredNode(mSelectedNode, iColors);

				DrawAttachedEdgeNodes(mSelectedNode, iClosestEdge);
			}
		}
		case EditMode_EditAttachment, EditMode_EditAttachmentAttributes, EditMode_EditAttachmentsList: {
			NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;

			bool bSkipUpdate = false;
			NavNode mNearestNode;
			if (g_eNavEdit[iClient].iEditMode == EditMode_EditAttachment) {
				SendEditAttachmentPanel(iClient);

				g_eNavEdit[iClient].mSelectedNode2 = NULL_NAV_NODE;
				mNearestNode = GetNearestNode(vecAimPos);
			} else {
				mNearestNode = g_eNavEdit[iClient].mSelectedNode2;
				bSkipUpdate = true;
			}

			if (mNearestNode && (bSkipUpdate || mNearestNode.Contains(vecAimPos) && mNearestNode != mSelectedNode)) {
				float vecPoint[3];
				int iVertices = mNearestNode.iVertices;

				int iClosestEdge;
				if (bSkipUpdate) {
					iClosestEdge = g_eNavEdit[iClient].iSelectedEdge2;
				} else {
					iClosestEdge = 0;
					mNearestNode.GetEdgeCenter(0, vecPoint);

					float fMinEdgeDistance = GetVectorDistance(vecAimPos, vecPoint);
					for (int i=1; i<iVertices; i++) {
						mNearestNode.GetEdgeCenter(i, vecPoint);
						float fDistance = GetVectorDistance(vecAimPos, vecPoint);
						if (fDistance < fMinEdgeDistance) {
							fMinEdgeDistance = fDistance;
							iClosestEdge = i;
						}
					}
				}

				float vecVertexA[3], vecVertexB[3];
				float vecSelectedDir[3], vecSelected2Dir[3];
				mSelectedNode.GetEdgeCenter(g_eNavEdit[iClient].iSelectedEdge, vecVertexA);
				mNearestNode.GetEdgeCenter(iClosestEdge, vecVertexB);

				if (!bSkipUpdate) {
					mSelectedNode.GetOrigin(vecSelectedDir);
					mNearestNode.GetOrigin(vecSelected2Dir);
					SubtractVectors(vecVertexA, vecSelectedDir, vecSelectedDir);
					SubtractVectors(vecVertexB, vecSelected2Dir, vecSelected2Dir);
					vecSelectedDir[2] = 0.0;
					vecSelected2Dir[2] = 0.0;
					NormalizeVector(vecSelectedDir, vecSelectedDir);
					NormalizeVector(vecSelected2Dir, vecSelected2Dir);
				}

				// At least 90 degrees difference (i.e. at right angle or opposite-facing)
				if (bSkipUpdate || true || GetVectorDotProduct(vecSelectedDir, vecSelected2Dir) <= 0.0) {
					float vecDiff[3];
					SubtractVectors(vecVertexB, vecVertexA, vecDiff);
					vecDiff[2] = 0.0;
					NormalizeVector(vecDiff, vecDiff);

// 					PrintToServer("GetVectorDotProduct to node %d = %.2f", mNearestNode, GetVectorDotProduct(vecSelectedDir, vecDiff));

					// Connection between nodes must be a bit less than perpendicular to the surface of each polygon
					if (bSkipUpdate || true || GetVectorDotProduct(vecSelectedDir, vecDiff) > 0.025 &&
						GetVectorDotProduct(vecSelected2Dir, vecDiff) < -0.025) {
						if (!bSkipUpdate) {
							g_eNavEdit[iClient].mSelectedNode2 = mNearestNode;
							g_eNavEdit[iClient].iSelectedEdge2 = iClosestEdge;
						}

						DrawNode(mNearestNode, COLOR_YELLOW);

						ScaleVector(vecDiff, 12.5);

						AddVectors(vecVertexB, vecDiff, vecVertexB);
						SubtractVectors(vecVertexA, vecDiff, vecVertexA);

						DrawDebugLine(vecVertexA, vecVertexB, COLOR_GREEN, 0.1, 1.0);
					}
				}
			}

			int iVertices = mSelectedNode.iVertices;
			int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
			int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

			static int iColors[MAX_VERTICES][4];
			for (int i=0; i<iVertices; i++) {
				iColors[i] = (i == iSelectedEdge) ? COLOR_YELLOW : COLOR_WHITE;
				iColors[i][3] = 0;
			}
			
			DrawColoredNode(mSelectedNode, iColors);

			if (iSelectedAttachment == -1) {
				DrawAttachedEdgeNodes(mSelectedNode, iSelectedEdge);
			} else {
				DrawAttachedEdgeNode(mSelectedNode, iSelectedEdge, iSelectedAttachment, COLOR_YELLOW);
			}
		}
	}

	return Plugin_Continue;
}

// Custom callbacks

public bool TraceEntityFilter_Environment(int iEntity, int iContentsMask) {
	return false;
}

// Helpers

float GetTraceEndpoint(const float vecPos[3], const float vecAng[3], float vecPosEnd[3], float vecNormal[3]=NULL_VECTOR) {
	Handle hTr = TR_TraceRayFilterEx(vecPos, vecAng, MASK_PLAYERSOLID, RayType_Infinite, TraceEntityFilter_Environment);
	if (TR_DidHit(hTr)) {
		TR_GetEndPosition(vecPosEnd, hTr);
		TR_GetPlaneNormal(hTr, vecNormal);
		delete hTr;

		return GetVectorDistance(vecPos, vecPosEnd);
	}
	delete hTr;

	return 0.0;
}

bool CheckVisibility(const float vecPos[3], const float vecPosTarget[3], float vecPosEnd[3]=NULL_VECTOR) {
	Handle hTr = TR_TraceRayFilterEx(vecPos, vecPosTarget, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilter_Environment);
	if (!TR_DidHit(hTr)) {
		vecPosEnd = vecPosTarget;
		delete hTr;
		return true;
	}

	TR_GetEndPosition(vecPosEnd, hTr);
	delete hTr;

	return false;
}

void DrawDebugLine(float vecPosA[3], float vecPosB[3], int iColor[4], float fLife=0.1, float fThickness=1.0, int iClients[MAXPLAYERS+1]={0, ...}, int iClientCount=-1) {
	TE_SetupBeamPoints(vecPosA, vecPosB, g_iLaser, g_iHalo, 0, 66, fLife, fThickness, fThickness, 1, 0.0, iColor, 0);
	if (iClientCount == -1) {
		TE_SendToAll();
	} else {
		TE_Send(iClients, iClientCount);
	}
}

void DrawAimCross(float vecAimPos[3]) {
	float vecGround[3];
	bool bAimOnGround = GetTraceEndpoint(vecAimPos, ANG_DOWN, vecGround) == 0.0;
	
	float vecCrossA[3], vecCrossB[3];

	vecCrossA = vecAimPos;
	vecCrossB = vecAimPos;
	vecCrossA[0] -= CROSSHAIR_SIZE;
	vecCrossB[0] += CROSSHAIR_SIZE;
	DrawDebugLine(vecCrossA, vecCrossB, COLOR_RED);

	vecCrossA = vecAimPos;
	vecCrossB = vecAimPos;
	vecCrossA[1] -= CROSSHAIR_SIZE;
	vecCrossB[1] += CROSSHAIR_SIZE;
	DrawDebugLine(vecCrossA, vecCrossB, COLOR_GREEN);

	vecCrossA = vecAimPos;
	vecCrossB = vecAimPos;
	vecCrossA[2] -= CROSSHAIR_SIZE;
	vecCrossB[2] += CROSSHAIR_SIZE;
	DrawDebugLine(vecCrossA, vecCrossB, bAimOnGround ? COLOR_BLUE : COLOR_CYAN);
}

void DrawColoredHull(float vecHull[MAX_VERTICES][3], int iHullVertices, int iColors[MAX_VERTICES][4]) {
	for (int i=1; i<iHullVertices; i++) {
		DrawDebugLine(vecHull[i-1], vecHull[i], iColors[i-1], 0.2);
	}

	DrawDebugLine(vecHull[iHullVertices-1], vecHull[0], iColors[iHullVertices-1], 0.2);
}

void DrawHull(float vecHull[MAX_VERTICES][3], int iHullVertices, int iColor[4]) {
	int iColors[MAX_VERTICES][4];
	for (int i=0; i<iHullVertices; i++) {
		iColors[i] = iColor;
	}

	DrawColoredHull(vecHull, iHullVertices, iColors);
}

// void DrawColoredNode(NavNode mNavNode, int iColors[MAX_VERTICES][4], bool bSameColor=false) {
// 	float vecVertices[MAX_VERTICES][3];
// 	int iVertices = mNavNode.iVertices;
// 	mNavNode.GetVertices(vecVertices, iVertices);

// 	DrawColoredHull(vecVertices, iVertices, iColors, bSameColor);
// }

void DrawNode(NavNode mNavNode, int iColor[4]=COLOR_DEFAULT, bool bForceColors=false) {
	int iColors[MAX_VERTICES][4];
	for (int i=0; i<MAX_VERTICES; i++) {
		iColors[i] = iColor;
	}

	DrawColoredNode(mNavNode, iColors, bForceColors);
}

void DrawColoredNode(NavNode mNavNode, int iColors[MAX_VERTICES][4], bool bForceColors=false) {
// 	float vecVertices[MAX_VERTICES][3];
// 	int iVertices = mNavNode.iVertices;
// 	mNavNode.GetVertices(vecVertices, iVertices);

// 	DrawHull(vecVertices, iVertices, iColor);
// }

// void DrawNodeAttachments(NavNode mNavNode) {

	float vecVertices[MAX_VERTICES][3];
	int iVertices;
	mNavNode.GetVertices(vecVertices, iVertices);

	if (bForceColors) {
		DrawColoredHull(vecVertices, iVertices, iColors);
		return;
	}

	for (int i=0; i<iVertices; i++) {
		int iCombinedAttachmentFlags;

		int iAttachmentsLength = mNavNode.GetAttachmentsLength(i);
		for (int j=0; j<iAttachmentsLength; j++) {
			int iAttachmentFlags;
			mNavNode.GetAttachment(i, j, _, _, iAttachmentFlags);
			iCombinedAttachmentFlags |= iAttachmentFlags;
		}

		if (iColors[i][3]) {
			continue;
		}

		if (!iCombinedAttachmentFlags) {
// 			iColors[i] = COLOR_WHITE;
			iColors[i][3] = 255;
		} else {
			GetAttachmentColor(iCombinedAttachmentFlags, iColors[i]);
		}
	}

	DrawColoredHull(vecVertices, iVertices, iColors);
}

void DrawAttachedNodes(NavNode mNavNode, int iColor[4]=COLOR_DEFAULT) {
	// Draw attached nodes
	int iVertices = mNavNode.iVertices;
	for (int i=0; i<iVertices; i++) {
		DrawAttachedEdgeNodes(mNavNode, i, iColor);
	}
}

void DrawAttachedEdgeNodes(NavNode mNavNode, int iEdge, int iColor[4]=COLOR_DEFAULT) {
	int iAttachmentsLength = mNavNode.GetAttachmentsLength(iEdge);
	for (int i=0; i<iAttachmentsLength; i++) {
		DrawAttachedEdgeNode(mNavNode, iEdge, i, iColor);
	}
}

void DrawAttachedEdgeNode(NavNode mNavNode, int iEdge, int iAttachment, int iColor[4]) {
	NavNode mAttachedNode;
	int iAttachedNodeEdge;
	int iAttachmentFlags;
	mNavNode.GetAttachment(iEdge, iAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);

	if (!mAttachedNode) {
		return;
	}

	DrawNode(mAttachedNode, iColor);

	float vecNodeOverlapEdge[2][3];
	mNavNode.GetEdgeOverlap(iEdge, mAttachedNode, iAttachedNodeEdge, vecNodeOverlapEdge[0], vecNodeOverlapEdge[1]);

	float vecAttachedNodeOverlapEdge[2][3];
	mAttachedNode.GetEdgeOverlap(iAttachedNodeEdge, mNavNode, iEdge, vecAttachedNodeOverlapEdge[0], vecAttachedNodeOverlapEdge[1]);

	float vecVertexA[3], vecVertexB[3];
	AddVectors(vecNodeOverlapEdge[0], vecNodeOverlapEdge[1], vecVertexA);
	ScaleVector(vecVertexA, 0.5);

	AddVectors(vecAttachedNodeOverlapEdge[0], vecAttachedNodeOverlapEdge[1], vecVertexB);
	ScaleVector(vecVertexB, 0.5);

// 	mNavNode.GetEdgeCenter(iEdge, vecVertexA);
// 	mAttachedNode.GetEdgeCenter(iAttachedNodeEdge, vecVertexB);

	int iAttachmentColorA[4], iAttachmentColorB[4];
	GetAttachmentColor(iAttachmentFlags, iAttachmentColorB);

	int iAttachedNodeAttachment = mAttachedNode.FindAttachment(iAttachedNodeEdge, mNavNode);
	int iAttachedNodeAttachmentFlags;
	if (iAttachedNodeAttachment != -1) {
		mAttachedNode.GetAttachment(iAttachedNodeEdge, iAttachedNodeAttachment, _, _, iAttachedNodeAttachmentFlags);
		GetAttachmentColor(iAttachedNodeAttachmentFlags, iAttachmentColorA);
	} else {
		iAttachmentColorA = iAttachmentColorB;
	}

	const float fArrowLength = 15.0;

	float vecDiff[3];
	SubtractVectors(vecVertexB, vecVertexA, vecDiff);

	vecDiff[2] = 0.0;
	NormalizeVector(vecDiff, vecDiff);
	ScaleVector(vecDiff, 1.5*fArrowLength);

	AddVectors(vecVertexB, vecDiff, vecVertexB);
	SubtractVectors(vecVertexA, vecDiff, vecVertexA);

	float vecVertexATemp[3], vecVertexBTemp[3];
	CheckVisibility(vecVertexA, vecVertexB, vecVertexBTemp);
	CheckVisibility(vecVertexB, vecVertexA, vecVertexATemp);
	float fDistAB = GetVectorDistance(vecVertexA, vecVertexBTemp);
	float fDistBA = GetVectorDistance(vecVertexB, vecVertexATemp);

// 	PrintToServer("vA=(%.1f, %.1f, %.1f), vATemp=(%.1f, %.1f, %.1f), vB=(%.1f, %.1f, %.1f), vbTemp=(%.1f, %.1f, %.1f), fDistAB=%.1f, fDistBA=%.1f",
// 		vecVertexA[0], vecVertexA[1], vecVertexA[2],
// 		vecVertexATemp[0], vecVertexATemp[1], vecVertexATemp[2],
// 		vecVertexB[0], vecVertexB[1], vecVertexB[2],
// 		vecVertexBTemp[0], vecVertexBTemp[1], vecVertexBTemp[2],
// 		fDistAB, fDistBA);

	if (fDistAB > 0.1) {
		vecVertexB = vecVertexBTemp;
	}

	if (fDistBA > 0.1) {
		vecVertexA = vecVertexATemp;
	}

	float vecVertexCenter[3];
	AddVectors(vecVertexA, vecVertexB, vecVertexCenter);
	ScaleVector(vecVertexCenter, 0.5);

	if (iAttachmentColorA[0] == iAttachmentColorB[0] &&
		iAttachmentColorA[1] == iAttachmentColorB[1] &&
		iAttachmentColorA[2] == iAttachmentColorB[2]) {
		DrawDebugLine(vecVertexA, vecVertexB, iAttachmentColorA, 0.3, 1.0);
	} else {
		DrawDebugLine(vecVertexA, vecVertexCenter, iAttachmentColorA, 0.3, 1.0);
		DrawDebugLine(vecVertexB, vecVertexCenter, iAttachmentColorB, 0.3, 1.0);
	}


	if (iAttachmentFlags == iAttachedNodeAttachmentFlags && iAttachedNodeAttachment != -1) {
		return;
	}

	float vecAngles[3];
	SubtractVectors(vecVertexB, vecVertexA, vecAngles);
	GetVectorAngles(vecAngles, vecAngles);

	float vecArrowA[3], vecArrowB[3];
	
	float vecFwd[3], vecRight[3], vecUp[3];
	GetAngleVectors(vecAngles, vecFwd, vecRight, vecUp);
	ScaleVector(vecFwd, fArrowLength);
	ScaleVector(vecRight, fArrowLength);
// 	ScaleVector(vecRight, 0.25*fArrowLength);

	SubtractVectors(vecVertexB, vecFwd, vecArrowA);
	vecArrowB = vecArrowA;
	AddVectors(vecArrowA, vecRight, vecArrowA);
	SubtractVectors(vecArrowB, vecRight, vecArrowB);

	DrawDebugLine(vecVertexB, vecArrowA, iAttachmentColorB, 0.3, 1.0);
	DrawDebugLine(vecVertexB, vecArrowB, iAttachmentColorB, 0.3, 1.0);

	if (iAttachedNodeAttachment != -1) {
		AddVectors(vecVertexA, vecFwd, vecArrowA);
		vecArrowB = vecArrowA;
		AddVectors(vecArrowA, vecRight, vecArrowA);
		SubtractVectors(vecArrowB, vecRight, vecArrowB);

		DrawDebugLine(vecVertexA, vecArrowA, iAttachmentColorA, 0.3, 1.0);
		DrawDebugLine(vecVertexA, vecArrowB, iAttachmentColorA, 0.3, 1.0);
	}
}

void GetAttachmentColor(int iAttachmentFlags, int iColor[4]) {
	if (iAttachmentFlags & FL_ATTACH_BLOCKED) {
		iColor = COLOR_RED;
	} else if (iAttachmentFlags & (FL_ATTACH_SOLID | FL_ATTACH_WALL)) {
		iColor = COLOR_MAGENTA;
	} else if (iAttachmentFlags & FL_ATTACH_GROUND) {
		iColor = COLOR_CYAN;
	} else if (iAttachmentFlags & FL_ATTACH_DROP) {
		iColor = COLOR_GREEN;
	} else if (iAttachmentFlags & FL_ATTACH_AIR_GAP) {
		iColor = COLOR_ORANGE;
	} else {
		iColor = COLOR_WHITE;
	}
}

void SnapToGrid(float vecPos[3], const int iSnapInterval) {
	vecPos[0] = float(RoundToNearest(vecPos[0] / iSnapInterval) * iSnapInterval);
	vecPos[1] = float(RoundToNearest(vecPos[1] / iSnapInterval) * iSnapInterval);

	float vecTraceStart[3];
	vecTraceStart[0] = vecPos[0];
	vecTraceStart[1] = vecPos[1];
	vecTraceStart[2] = vecPos[2] + 10.0;

	float vecTraceEnd[3];
	if (GetTraceEndpoint(vecTraceStart, {90.0, 00.0, 0.0}, vecTraceEnd)) {
		vecPos[2] = vecTraceEnd[2];
	}
}

float GetVectorLength2D(float vecVector[3]) {
	float vecVector2D[3];
	vecVector2D[0] = vecVector[0];
	vecVector2D[1] = vecVector[1];
	return GetVectorLength(vecVector2D);
}

void ResetClient(int iClient, bool bFullReset=true) {
	g_eNavEdit[iClient].iEditMode = EditMode_Off;
	if (bFullReset) {
		g_eNavEdit[iClient].iSnapToGrid = MIN_SNAP_GRID;
		g_eNavEdit[iClient].iVertices = DEFAULT_VERTICES;
	}
	g_eNavEdit[iClient].mSelectedNode = NULL_NAV_NODE;
	g_eNavEdit[iClient].mSelectedNode2 = NULL_NAV_NODE;

	g_eNavEdit[iClient].iCurrentVertex = -1;
	g_eNavEdit[iClient].bStartedCenter = false;
	g_eNavEdit[iClient].bStartedDiagonal = false;

	g_eNavEdit[iClient].iSelectedVertex = -1;
	g_eNavEdit[iClient].iSelectedEdge = -1;
	g_eNavEdit[iClient].iSelectedEdge2 = -1;

	g_eNavEdit[iClient].iSelectedAttachment = -1;
}

// Adapted from https://www.geeksforgeeks.org/orientation-3-ordered-points/
Orientation GetOrientation2D(float vec1[3], float vec2[3], float vec3[3]) {
	float fVal =	(vec2[1]-vec1[1]) * (vec3[0]-vec2[0]) - 
					(vec2[0]-vec1[0]) * (vec3[1]-vec2[1]);

	if (FloatAbs(fVal) < 0.0001) {
		return Orientation_Colinear;
	}

	return fVal > 0 ? Orientation_Clockwise : Orientation_CounterClockwise;
}

// Adapted from https://www.geeksforgeeks.org/convex-hull-set-1-jarviss-algorithm-or-wrapping/
void GetConvexHull(float vecPoints[MAX_VERTICES][3], int iVertices, float vecHull[MAX_VERTICES][3], int &iHullVertices) {
	iHullVertices = 0;

	if (iVertices <= 0) {
		return;
	}

	int iLeftMostIdx = 0;
	for (int i=1; i<iVertices; i++) {
		if (vecPoints[iLeftMostIdx][0] < vecPoints[i][0]) {
			iLeftMostIdx = i;
		}
	}

	int iPointIdx = iLeftMostIdx;
	do {
		vecHull[iHullVertices++] = vecPoints[iPointIdx];

		int iQueryIdx = (iPointIdx+1) % iVertices;

		for (int i=0; i<iVertices; i++) {
			if (GetOrientation2D(vecPoints[iPointIdx], vecPoints[i], vecPoints[iQueryIdx]) == Orientation_CounterClockwise) {
				iQueryIdx = i;
			}
		}

		iPointIdx = iQueryIdx;
	} while (iPointIdx != iLeftMostIdx);

// 	PrintToServer("GetConvexHull %d -> %d points", iVertices, iHullVertices);
}


int UpdateNavNodeHull(int iClient, int iVertices, bool bBuildConvexHull=true) {
	static float vecPoints[MAX_VERTICES][3];
	static float vecHull[MAX_VERTICES][3];
	static int iHullVertices;

	for (int i=0; i<iVertices; i++) {
		g_eNavEdit[iClient].GetVertex(i, vecPoints[i]);
	}

	if (bBuildConvexHull) {
		GetConvexHull(vecPoints, iVertices, vecHull, iHullVertices);
		
		g_eNavEdit[iClient].vecNodeOrigin = NULL_VECTOR;
		for (int i=0; i<iVertices; i++) {
			g_eNavEdit[iClient].SetVertex(i, vecHull[i]);
			AddVectors(g_eNavEdit[iClient].vecNodeOrigin, vecHull[i], g_eNavEdit[iClient].vecNodeOrigin);
		}
		ScaleVector(g_eNavEdit[iClient].vecNodeOrigin, 1.0/iHullVertices);

		return iHullVertices;
	}

	g_eNavEdit[iClient].vecNodeOrigin = NULL_VECTOR;
	for (int i=0; i<iVertices; i++) {
		AddVectors(g_eNavEdit[iClient].vecNodeOrigin, vecPoints[i], g_eNavEdit[iClient].vecNodeOrigin);
	}
	ScaleVector(g_eNavEdit[iClient].vecNodeOrigin, 1.0/iVertices);

	return iVertices;
}

void AddNavNode(int iClient, int iVertices) {
	NavNode mNavNode = NavNode.Instance();
	mNavNode.SetOrigin(g_eNavEdit[iClient].vecNodeOrigin);

	float vecVertex[3];
	for (int i=0; i<iVertices; i++) {
		g_eNavEdit[iClient].GetVertex(i, vecVertex);
		mNavNode.SetVertex(i, vecVertex);
	}
	mNavNode.iVertices = iVertices;
	mNavNode.Update();

	ArrayList hNavNodes = g_mNavMesh.GetNodes();
	hNavNodes.Push(mNavNode);
	delete hNavNodes;

	g_mNavMesh.UpdateIndex();
}

NavNode GetNearestNode(float vecPoint[3]) {
	/*
	ArrayList hNearestNodes = new ArrayList();
	int iNearestNodesLength = g_mNavMesh.GetNodesInRange(vecPoint, NODE_PROXIMITY, hNearestNodes, true);
	float fMinDistance = POSITIVE_INFINITY;
	NavNode mNearestNode;

	for (int i=0; i<iNearestNodesLength; i++) {
		NavNode mNavNode = hNearestNodes.Get(i);
		float vecOrigin[3];
		mNavNode.GetOrigin(vecOrigin);

		float fDistance = GetVectorDistance(vecPoint, vecOrigin);
		if (fDistance < fMinDistance) {
			mNearestNode = mNavNode;
			fMinDistance = fDistance;
		}
	}

	delete hNearestNodes;

	return mNearestNode;
	*/

	return g_mNavMesh.GetNearestNodeInRange(vecPoint, NODE_PROXIMITY, true);
}

// From https://stackoverflow.com/a/12175897
int CountSetBits(int i) {
	i = i - ((i >> 1) & 0x55555555);
	i = (i & 0x33333333) + ((i >> 2) & 0x33333333);
	return (((i + (i >> 4)) & 0x0F0F0F0F) * 0x01010101) >> 24;
}

bool LoadNavFile(char[] sFileName, char[] sError, int iMaxErrorLength) {
	char sFilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFilePath, sizeof(sFilePath), "data/smbl/nav/%s.snav", sFileName);
	
	NavMesh.Destroy(g_mNavMesh);

	if (!FileExists(sFilePath)) {
		return false;
	}

	g_mNavMesh = NavMesh.LoadNavFile(sFilePath, sError, iMaxErrorLength);

	return g_mNavMesh != NULL_NAV_MESH;
}

bool SaveNavFile(char[] sFileName, char[] sError, int iMaxErrorLength) {
	char sFilePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFilePath, sizeof(sFilePath), "data/smbl/nav/%s.snav", sFileName);

	return NavMesh.SaveNavFile(g_mNavMesh, sFilePath, sError, iMaxErrorLength);
}

// Commands

public Action cmdNavEdit(int iClient, int iArgC) {
	if (!iClient) {
		ReplyToCommand(iClient, "[SMBL] This command cannot be run from server console.");
		return Plugin_Handled;
	}

	ResetClient(iClient, false);

	g_eNavEdit[iClient].iEditMode = EditMode_Default;
	SendNavEditPanel(iClient);

	return Plugin_Handled;
}

public Action cmdNavEditLoad(int iClient, int iArgC) {
	char sFileName[32];

	if (iArgC == 0) {
		GetCurrentMap(sFileName, sizeof(sFileName));
	} else {
		GetCmdArg(1, sFileName, sizeof(sFileName));
	}

	char sError[64+PLATFORM_MAX_PATH];
	if (LoadNavFile(sFileName, sError, sizeof(sError))) {
		ReplyToCommand(iClient, "[SMBL] Loaded nav mesh");
		return Plugin_Handled;
	} else if (sError[0]) {
		ReplyToCommand(iClient, "[SMBL] Failed to load nav mesh (%s)", sError);
		return Plugin_Handled;
	}

	ReplyToCommand(iClient, "[SMBL] No nav mesh to load");

	return Plugin_Handled;
}

public Action cmdNavEditSave(int iClient, int iArgC) {
	char sFileName[32];

	if (iArgC == 0) {
		GetCurrentMap(sFileName, sizeof(sFileName));
	} else {
		GetCmdArg(1, sFileName, sizeof(sFileName));
	}

	char sError[64+PLATFORM_MAX_PATH];

	if (SaveNavFile(sFileName, sError, sizeof(sError))) {
		ReplyToCommand(iClient, "[SMBL] Saved nav mesh");
	} else {
		ReplyToCommand(iClient, "[SMBL] Failed to save nav mesh (%s)", sError);
	}

	return Plugin_Handled;
}

public Action cmdNavEditClear(int iClient, int iArgC) {
	if (g_mNavMesh) {
		NavMesh.Destroy(g_mNavMesh);
		g_mNavMesh = NavMesh.Instance();
	}

	ReplyToCommand(iClient, "[SMBL] Cleared nav mesh");

	return Plugin_Handled;
}

// Menus

void SendNavEditPanel(int iClient) {
	static char sBuffer[64];

	Panel hPanel = new Panel();
	hPanel.SetTitle("Navigation Mesh Editor");
	hPanel.DrawText(" ");

	DrawCoords(iClient, hPanel);
	hPanel.DrawText(" ");

	bool bHasSelection = g_eNavEdit[iClient].mSelectedNode != NULL_NAV_NODE;

	hPanel.DrawItem("Add Node");

	hPanel.DrawItem("Edit Node",	bHasSelection ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	hPanel.DrawItem("Delete Node", 	bHasSelection ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	hPanel.DrawText(" ");

	hPanel.CurrentKey = 4;
	IntToString(g_eNavEdit[iClient].iSnapToGrid, sBuffer, sizeof(sBuffer));
	Format(sBuffer, sizeof(sBuffer), "Snap to Grid: %s", g_eNavEdit[iClient].iSnapToGrid ? sBuffer: "OFF");
	hPanel.DrawItem(sBuffer);

	hPanel.DrawText(" ");

	hPanel.CurrentKey = 10;
	hPanel.DrawItem("Exit");

	hPanel.Send(iClient, MenuHandler_NavEdit, 0);
	delete hPanel;
}

void SendAddNodePanel(int iClient) {
	static char sBuffer[64];

	Panel hPanel = new Panel();
	hPanel.SetTitle("Add Navigation Node");
	hPanel.DrawText(" ");

	DrawCoords(iClient, hPanel);
	hPanel.DrawText(" ");

	int iCurrentVertex = g_eNavEdit[iClient].iCurrentVertex;
	int iVertices = g_eNavEdit[iClient].iVertices;

	bool bStartedCenter = g_eNavEdit[iClient].bStartedCenter;
	bool bStartedDiagonal = g_eNavEdit[iClient].bStartedDiagonal;

	if (bStartedCenter) {
		hPanel.DrawItem("Start Point", ITEMDRAW_DISABLED);
		hPanel.DrawItem("End Scale");
		hPanel.DrawItem("Start Diagonal", ITEMDRAW_DISABLED);
	} else if (bStartedDiagonal) {
		hPanel.DrawItem("Start Point", ITEMDRAW_DISABLED);
		hPanel.DrawItem("Start Center", ITEMDRAW_DISABLED);
		hPanel.DrawItem("End Diagonal");
	} else {
		if (iCurrentVertex == -1) {
			hPanel.DrawItem("Start Point");
		} else {
			FormatEx(sBuffer, sizeof(sBuffer), "Next Point (%d/%d)", iCurrentVertex+1, MAX_VERTICES);
			hPanel.DrawItem(sBuffer);

		}

		hPanel.DrawItem("Start Center",	iCurrentVertex == -1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
		hPanel.DrawItem("Start Diagonal",	iCurrentVertex == -1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}

	hPanel.DrawText(" ");

	if (iCurrentVertex >= 3) {
		FormatEx(sBuffer, sizeof(sBuffer), "Finish Polygon (%d)", iCurrentVertex);
		hPanel.DrawItem(sBuffer);
	} else if (bStartedCenter || bStartedDiagonal) {
		FormatEx(sBuffer, sizeof(sBuffer), "Sides: %d", iVertices);
		hPanel.DrawItem(sBuffer);
// 		hPanel.DrawItem(sBuffer, iCurrentVertex == -1 && !bStartedCenter && !bStartedDiagonal ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	} else {
		hPanel.DrawText(" ");
	}
	
	hPanel.DrawText(" ");

	hPanel.CurrentKey = 8;
	hPanel.DrawItem("Back");

	hPanel.Send(iClient, MenuHandler_NavAddNode, 0);
	delete hPanel;
}

void SendEditNodePanel(int iClient) {
	static char sBuffer[64];

	bool bVertexSelected = g_eNavEdit[iClient].iSelectedVertex != -1;
	bool bEdgeSelected = g_eNavEdit[iClient].iSelectedEdge != -1;

	int iVertices = g_eNavEdit[iClient].iVertices;
	bool bCanAddVertex = iVertices < MAX_VERTICES;

	int iAttachmentsLength = bEdgeSelected ? g_eNavEdit[iClient].mSelectedNode.GetAttachmentsLength(g_eNavEdit[iClient].iSelectedEdge) : 0;
	bool bCanAddAttachment = bEdgeSelected && iAttachmentsLength < MAX_EDGE_ATTACHMENTS;

	Panel hPanel = new Panel();
	hPanel.SetTitle("Edit Navigation Node");
	hPanel.DrawText(" ");

	DrawCoords(iClient, hPanel);
	FormatEx(sBuffer, sizeof(sBuffer), "Sides: %d %s", g_eNavEdit[iClient].iVertices, bCanAddVertex ? "" : "(MAX)");
	hPanel.DrawText(sBuffer);

	hPanel.DrawText(" ");

	hPanel.DrawItem("Add Vertex",		bCanAddVertex && bCanAddAttachment ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	hPanel.DrawItem("Edit Vertex",		bVertexSelected ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	hPanel.DrawText(" ");

	hPanel.DrawItem("Add Attachment",	bCanAddAttachment ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	FormatEx(sBuffer, sizeof(sBuffer), "Edit Attachments (%d)", iAttachmentsLength);
	hPanel.DrawItem(sBuffer,			bEdgeSelected && iAttachmentsLength ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	hPanel.DrawText(" ");

// 	hPanel.DrawItem("Move Node");
// 	hPanel.DrawItem("Transform Node");

// 	hPanel.DrawText(" ");

	hPanel.CurrentKey = 8;
	hPanel.DrawItem("Back");

	hPanel.Send(iClient, MenuHandler_NavEditNode, 0);
	delete hPanel;
}

void SendEditAttachmentsListMenu(int iClient) {
	static char sBuffer[64];

	Menu hMenu = new Menu(MenuHandler_EditAttachmentsList);
	hMenu.SetTitle("Attachments");

	NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
	int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
	int iAttachmentsLength = mSelectedNode.GetAttachmentsLength(iSelectedEdge);

	ArrayList hNavNodes = g_mNavMesh.GetNodes();
	for (int i=0; i<iAttachmentsLength; i++) {
		NavNode mAttachedNode;
		int iAttachedNodeEdge;
		int iAttachmentFlags;
		mSelectedNode.GetAttachment(iSelectedEdge, i, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);

		FormatEx(sBuffer, sizeof(sBuffer), mAttachedNode ? "NODE-%d (EDGE-%d)" : "None", hNavNodes.FindValue(mAttachedNode), iAttachedNodeEdge);
		Format(sBuffer, sizeof(sBuffer), "[%d]: %s", i, sBuffer);
		hMenu.AddItem(NULL_STRING, sBuffer);
	}
	delete hNavNodes;

	hMenu.ExitBackButton = true;

	hMenu.Display(iClient, 0);
}

void SendEditAttachmentPanel(int iClient) {
	static char sBuffer[64];

	Panel hPanel = new Panel();
	FormatEx(sBuffer, sizeof(sBuffer), "Edit Attachment [%d]", g_eNavEdit[iClient].iSelectedAttachment);

	hPanel.SetTitle(sBuffer);
	hPanel.DrawText(" ");

	DrawCoords(iClient, hPanel);
	hPanel.DrawText(" ");

	NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
	NavNode mSelectedNode2 = g_eNavEdit[iClient].mSelectedNode2;
	int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
	
	NavNode mAttachedNode;
	int iAttachedNodeEdge;
	int iAttachmentFlags;
	mSelectedNode.GetAttachment(iSelectedEdge, g_eNavEdit[iClient].iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);

	ArrayList hNavNodes = g_mNavMesh.GetNodes();
	int iAttachedNodeIdx = mAttachedNode ? hNavNodes.FindValue(mAttachedNode) : -1;
	int iSelectedNode2Idx = g_eNavEdit[iClient].mSelectedNode2 ? hNavNodes.FindValue(mSelectedNode2) : -1;
	delete hNavNodes;

	bool bTargetAttachmentFound = mSelectedNode.FindAttachment(iSelectedEdge, mSelectedNode2) != -1;

	bool bAttachedNode = iAttachedNodeIdx != -1;
	bool bReverseAttachedNode = false;

	if (bAttachedNode) {
		FormatEx(sBuffer, sizeof(sBuffer), "Attached: NODE-%d", iAttachedNodeIdx);
		hPanel.DrawText(sBuffer);

		int iAttachmentsLength = mAttachedNode.GetAttachmentsLength(iAttachedNodeEdge);
		for (int i=0; i<iAttachmentsLength && !bReverseAttachedNode; i++) {
			if (mAttachedNode.FindAttachment(iAttachedNodeEdge, mSelectedNode) != -1) {
				bReverseAttachedNode = true;
			}
		}
	} else {
		hPanel.DrawText("Attached: None");
	}

	bool bSelectedNode2 = iSelectedNode2Idx != -1;
	if (bSelectedNode2) {
		FormatEx(sBuffer, sizeof(sBuffer), "Target: NODE-%d %s", iSelectedNode2Idx, bTargetAttachmentFound ? "(Already Attached)" : "");
		hPanel.DrawText(sBuffer);
	} else {
		hPanel.DrawText("Target: None");
	}

	hPanel.DrawText(" ");
	
	hPanel.DrawText("Change connectivity:");
	
	hPanel.DrawText(" ");
	
	FormatEx(sBuffer, sizeof(sBuffer), "[%s] Unidirectional", bAttachedNode && !bReverseAttachedNode ? 'x' : ' ');
	hPanel.DrawItem(sBuffer, mAttachedNode ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);	
	
	FormatEx(sBuffer, sizeof(sBuffer), "[%s] Bidirectional", bAttachedNode && bReverseAttachedNode ? 'x' : ' ');
	hPanel.DrawItem(sBuffer, mAttachedNode ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);	
	
	FormatEx(sBuffer, sizeof(sBuffer), "[%s] None", !bAttachedNode && !bReverseAttachedNode ? 'x' : ' ');
	hPanel.DrawItem(sBuffer, mAttachedNode ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);	

	hPanel.DrawText(" ");

	hPanel.DrawItem("Change attached node", bTargetAttachmentFound ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

	hPanel.DrawText(" ");

	FormatEx(sBuffer, sizeof(sBuffer), "Change Attributes (%d)", CountSetBits(iAttachmentFlags));
	hPanel.DrawItem(sBuffer);

	hPanel.DrawItem("Delete Attachment");	

	hPanel.DrawText(" ");

	hPanel.CurrentKey = 8;
	hPanel.DrawItem("Back");

	hPanel.Send(iClient, MenuHandler_EditAttachment, 0);
	delete hPanel;
}

void SendEditAttachmentAttributesMenu(int iClient, int iSelection=0) {
	static char sBuffer[64];

	Menu hMenu = new Menu(MenuHandler_EditAttachmentAttributes);
	hMenu.SetTitle("Attachment Attributes");

	NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
	int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
	int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

	int iAttachmentFlags;
	mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, _, _, iAttachmentFlags);

	for (int i=0; i<sizeof(g_sAttachFlags); i++) {
		FormatEx(sBuffer, sizeof(sBuffer), "[%s] %s", iAttachmentFlags & (1 << i) ? 'x' : ' ', g_sAttachFlags[i]);
		hMenu.AddItem(NULL_STRING, sBuffer);
	}

	hMenu.ExitBackButton  = true;

	hMenu.DisplayAt(iClient, iSelection, 0);
}

void DrawCoords(int iClient, Panel hPanel) {
	char sBuffer[64];

	float vecAimPos[3];
	vecAimPos = g_eNavEdit[iClient].vecAimPos;

	FormatEx(sBuffer, sizeof(sBuffer), "Coords: %.1f, %.1f, %.1f", vecAimPos[0], vecAimPos[1], vecAimPos[2]);
	hPanel.DrawText(sBuffer);

	bool bHasSelection = g_eNavEdit[iClient].mSelectedNode != NULL_NAV_NODE;

	if (bHasSelection) {
		ArrayList hNavNodes = g_mNavMesh.GetNodes();
		FormatEx(sBuffer, sizeof(sBuffer), "NODE-%d", hNavNodes.FindValue(g_eNavEdit[iClient].mSelectedNode));
		delete hNavNodes;
	} else {
		sBuffer = "None";
	}
	Format(sBuffer, sizeof(sBuffer), "Select: %s", sBuffer);
	hPanel.DrawText(sBuffer);
}

// Menu handlers

public int MenuHandler_NavEdit(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			switch (iOption) {
				case 1: {
					// Add node
					SendAddNodePanel(iClient);
					g_eNavEdit[iClient].iEditMode = EditMode_Add;
				}
				case 2: {
					// Edit node
					SendEditNodePanel(iClient);
					g_eNavEdit[iClient].iEditMode = EditMode_Edit;
				}
				case 3: {
					// Delete node
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					if (mSelectedNode) {
						ArrayList hNavNodes = g_mNavMesh.GetNodes();
						int iNavNodesLength = hNavNodes.Length;
						
						for (int i=0; i<iNavNodesLength; i++) {
							NavNode mNavNode = hNavNodes.Get(i);

							int iVertices = mNavNode.iVertices;
							for (int j=0; j<iVertices; j++) {
								int iAttachment = mNavNode.FindAttachment(j, mSelectedNode);
								if (iAttachment != -1) {
									mNavNode.EraseAttachment(j, iAttachment);
								}
							}
						}

						hNavNodes.Erase(hNavNodes.FindValue(mSelectedNode));
						delete hNavNodes;

						NavNode.Destroy(mSelectedNode);
						g_eNavEdit[iClient].mSelectedNode = NULL_NAV_NODE;
						g_mNavMesh.UpdateIndex();

						ResetClient(iClient, false);
						g_eNavEdit[iClient].iEditMode = EditMode_Default;
					}
				}
				case 4: {
					if (g_eNavEdit[iClient].iSnapToGrid == 0) {
						g_eNavEdit[iClient].iSnapToGrid = 1;
					} else {
						g_eNavEdit[iClient].iSnapToGrid *= SNAP_GRID_INCREMENT;
						if (g_eNavEdit[iClient].iSnapToGrid > MAX_SNAP_GRID) {
							g_eNavEdit[iClient].iSnapToGrid = 0;
						}
					}
					
					SendNavEditPanel(iClient);
				}
				default: {
					g_eNavEdit[iClient].iEditMode = EditMode_Off;
				}
			}
		}
	}

	return 0;
}

public int MenuHandler_NavAddNode(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			switch (iOption) {
				case 1: {
					if (g_eNavEdit[iClient].iCurrentVertex == -1) {
						g_eNavEdit[iClient].vecVertices[0] = g_eNavEdit[iClient].vecAimPos[0];
						g_eNavEdit[iClient].vecVertices[1] = g_eNavEdit[iClient].vecAimPos[1];
						g_eNavEdit[iClient].vecVertices[2] = g_eNavEdit[iClient].vecAimPos[2];

						g_eNavEdit[iClient].iCurrentVertex = 1;
					} else {
						int iOffset = 3*g_eNavEdit[iClient].iCurrentVertex++;
						g_eNavEdit[iClient].vecVertices[iOffset  ] = g_eNavEdit[iClient].vecAimPos[0];
						g_eNavEdit[iClient].vecVertices[iOffset+1] = g_eNavEdit[iClient].vecAimPos[1];
						g_eNavEdit[iClient].vecVertices[iOffset+2] = g_eNavEdit[iClient].vecAimPos[2];

						// More than 3 vertices
						if (g_eNavEdit[iClient].iCurrentVertex > 3) {
							int iHullVertices = UpdateNavNodeHull(iClient, g_eNavEdit[iClient].iCurrentVertex);
							g_eNavEdit[iClient].iCurrentVertex = iHullVertices;
						}

						if (g_eNavEdit[iClient].iCurrentVertex == MAX_VERTICES) {
							AddNavNode(iClient, g_eNavEdit[iClient].iCurrentVertex);

							ResetClient(iClient, false);
							g_eNavEdit[iClient].iEditMode = EditMode_Default;
						}
					}
				}
				case 2: {
					if (g_eNavEdit[iClient].bStartedCenter) {
						UpdateNavNodeHull(iClient, g_eNavEdit[iClient].iVertices, false);
						AddNavNode(iClient, g_eNavEdit[iClient].iVertices);

						ResetClient(iClient, false);
						g_eNavEdit[iClient].iEditMode = EditMode_Add;
					} else {
						g_eNavEdit[iClient].vecNodeOrigin = g_eNavEdit[iClient].vecAimPos;
						g_eNavEdit[iClient].bStartedCenter = true;
					}
				}
				case 3: {
					if (g_eNavEdit[iClient].bStartedDiagonal) {
						UpdateNavNodeHull(iClient, g_eNavEdit[iClient].iVertices, false);
						AddNavNode(iClient, g_eNavEdit[iClient].iVertices);

						ResetClient(iClient, false);
						g_eNavEdit[iClient].iEditMode = EditMode_Add;
					} else {
						g_eNavEdit[iClient].vecDiagStart = g_eNavEdit[iClient].vecAimPos;
						g_eNavEdit[iClient].bStartedDiagonal = true;
					}
				}
				case 4: {
					if (g_eNavEdit[iClient].iCurrentVertex == -1) {
						if (++g_eNavEdit[iClient].iVertices > MAX_VERTICES) {
							g_eNavEdit[iClient].iVertices = MIN_VERTICES;
						}
					} else {
						int iHullVertices = UpdateNavNodeHull(iClient, g_eNavEdit[iClient].iCurrentVertex);
						g_eNavEdit[iClient].iCurrentVertex = iHullVertices;
						AddNavNode(iClient, iHullVertices);

						ResetClient(iClient, false);
						g_eNavEdit[iClient].iEditMode = EditMode_Add;
					}
				}
				default: {
					ResetClient(iClient, false);
					g_eNavEdit[iClient].iEditMode = EditMode_Default;
				}
			}
		}
	}

	return 0;
}

public int MenuHandler_NavEditNode(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			switch (iOption) {
				case 1: {
				}
				case 3: {
					// Add attachment
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					NavNode mSelectedNode2 = g_eNavEdit[iClient].mSelectedNode2;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
					int iSelectedEdge2 = g_eNavEdit[iClient].iSelectedEdge2;

					if (mSelectedNode2) {
						g_eNavEdit[iClient].iSelectedAttachment = mSelectedNode.PushAttachment(iSelectedEdge, mSelectedNode2, iSelectedEdge2, 0);
					} else {
						g_eNavEdit[iClient].iSelectedAttachment = mSelectedNode.PushAttachment(iSelectedEdge, NULL_NAV_NODE, -1, 0);
					}

					g_eNavEdit[iClient].iEditMode = EditMode_EditAttachment;
				}
				case 4: {
					// Edit attachments
					SendEditAttachmentsListMenu(iClient);
					g_eNavEdit[iClient].iEditMode = EditMode_EditAttachmentsList;
				}
				default: {
					ResetClient(iClient, false);
					g_eNavEdit[iClient].iEditMode = EditMode_Default;
				}
			}
		}
	}

	return 0;
}

public int MenuHandler_EditAttachment(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			switch (iOption) {
				case 1: {
					// Unidirectional
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
					int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

					NavNode mAttachedNode;
					int iAttachedNodeEdge;
					mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, _);

					if (mAttachedNode) {
						int iAttachment = mAttachedNode.FindAttachment(iAttachedNodeEdge, mSelectedNode);
						if (iAttachment != -1) {
							mAttachedNode.EraseAttachment(iAttachedNodeEdge, iAttachment);
						}

						g_eNavEdit[iClient].mSelectedNode2 = NULL_NAV_NODE;
						g_eNavEdit[iClient].iSelectedEdge2 = -1;
					}

					g_eNavEdit[iClient].iEditMode = EditMode_EditAttachment;
				}
				case 2: {
					// Biidirectional
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
					int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

					NavNode mAttachedNode;
					int iAttachedNodeEdge;
					int iAttachmentFlags;
					mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);

					mAttachedNode.PushAttachment(iAttachedNodeEdge, mSelectedNode, iSelectedEdge, iAttachmentFlags);

					g_eNavEdit[iClient].iEditMode = EditMode_EditAttachment;
				}
				case 3: {
					// None
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
					int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

					NavNode mAttachedNode;
					int iAttachedNodeEdge;
					int iAttachmentFlags;
					mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);

					mSelectedNode.SetAttachment(iSelectedEdge, iSelectedAttachment, NULL_NAV_NODE, -1, iAttachmentFlags);

					if (mAttachedNode) {
						int iAttachment = mAttachedNode.FindAttachment(iAttachedNodeEdge, mSelectedNode);
						if (iAttachment != -1) {
							mAttachedNode.EraseAttachment(iAttachedNodeEdge, iAttachment);
						}
					}
				}
				case 4: {
					// Change attached node
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					NavNode mSelectedNode2 = g_eNavEdit[iClient].mSelectedNode2;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
					int iSelectedEdge2 = g_eNavEdit[iClient].iSelectedEdge2;
					int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;
					
					int iAttachmentFlags;
					mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, _, _, iAttachmentFlags);

					if (mSelectedNode2) {
						mSelectedNode.SetAttachment(iSelectedEdge, iSelectedAttachment, mSelectedNode2, iSelectedEdge2, iAttachmentFlags);
					} else {
						mSelectedNode.SetAttachment(iSelectedEdge, iSelectedAttachment, NULL_NAV_NODE, -1, iAttachmentFlags);
					}
				}
				case 5: {
					// Attributes
					g_eNavEdit[iClient].iEditMode = EditMode_EditAttachmentAttributes;
					SendEditAttachmentAttributesMenu(iClient);
				}
				case 6: {
					// Delete attachment
					NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
					int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;
					int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;

					mSelectedNode.EraseAttachment(iSelectedEdge, iSelectedAttachment);

					g_eNavEdit[iClient].mSelectedNode2 = NULL_NAV_NODE;
					g_eNavEdit[iClient].iEditMode = EditMode_Edit;
				}
				default: {
					g_eNavEdit[iClient].mSelectedNode2 = NULL_NAV_NODE;
					g_eNavEdit[iClient].iEditMode = EditMode_Edit;
				}
			}
		}
	}

	return 0;
}

public int MenuHandler_EditAttachmentAttributes(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			NavNode mSelectedNode = g_eNavEdit[iClient].mSelectedNode;
			int iSelectedEdge = g_eNavEdit[iClient].iSelectedEdge;
			int iSelectedAttachment = g_eNavEdit[iClient].iSelectedAttachment;

			NavNode mAttachedNode;
			int iAttachedNodeEdge;
			int iAttachmentFlags;
			mSelectedNode.GetAttachment(iSelectedEdge, iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags);
			mSelectedNode.SetAttachment(iSelectedEdge, iSelectedAttachment, mAttachedNode, iAttachedNodeEdge, iAttachmentFlags ^ (1 << iOption));

			SendEditAttachmentAttributesMenu(iClient, hMenu.Selection);
		}

		case MenuAction_Cancel: {
			if (iOption == MenuCancel_ExitBack) {
				g_eNavEdit[iClient].iEditMode = EditMode_EditAttachment;
			}
		}

		case MenuAction_End: {
			delete hMenu;
		}
	}

	return 0;
}

public int MenuHandler_EditAttachmentsList(Menu hMenu, MenuAction iAction, int iClient, int iOption) {
	switch (iAction) {
		case MenuAction_Select: {
			g_eNavEdit[iClient].iSelectedAttachment = iOption;
			g_eNavEdit[iClient].iEditMode = EditMode_EditAttachment;
		}

		case MenuAction_Cancel: {
			if (iOption == MenuCancel_ExitBack) {
				g_eNavEdit[iClient].iEditMode = EditMode_Edit;
			}
		}

		case MenuAction_End: {
			delete hMenu;
		}
	}

	return 0;
}
