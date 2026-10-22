import React from 'react';
import {Composition, Still} from 'remotion';
import './fonts';
import {Photo} from './Photo';
import {Launch} from './Launch';
import {Social, SocialOverlay, Teaser, TEASER_SECONDS} from './Cuts';
import {DURATION, FPS} from './timing';

export const Root: React.FC = () => (
  <>
    <Composition id="Launch" component={Launch} width={1920} height={1080} fps={FPS} durationInFrames={Math.round(DURATION * FPS)} />
    <Composition id="Social" component={Social} width={1080} height={1920} fps={FPS} durationInFrames={Math.round(DURATION * FPS)} />
    <Composition id="SocialOverlay" component={SocialOverlay} width={1080} height={1920} fps={30} durationInFrames={Math.round(DURATION * 30)} />
    <Composition id="Teaser" component={Teaser} width={1920} height={1080} fps={FPS} durationInFrames={TEASER_SECONDS * FPS} />
    <Still id="Photo" component={Photo} width={2400} height={1600} />
  </>
);
